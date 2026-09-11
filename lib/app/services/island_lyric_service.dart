import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/core/lyric_model.dart' as fl;

import '../state/settings_island_lyric.dart';
import 'cover_local_cache.dart';
import '../services/lyrics/lyrics_service.dart';
import '../services/player_service.dart';

/// 通知歌词灵动岛服务。
///
/// 监听 [LyricsService.currentLineText] 与 [PlayerService]，在「开关打开、正在
/// 播放、当前行有歌词」时，通过 MethodChannel 驱动原生层发送 HyperOS/MIUI
/// 「焦点通知」，让歌词渲染在系统灵动岛。暂停/停止/无歌词时隐藏。
///
/// 更新策略：
/// - 歌词行变化 → 立即发送（[shouldUpdate] 去重相同行）；
/// - 播放进度变化 → 节流发送（[_progressThrottle]，避免频繁刷新系统通知）。
///
/// 测试模式（[IslandLyricSettings.testMode]）：打开后即使不播放也持续模拟发送，
/// 用于验证暂停/无播放时灵动岛是否仍能渲染。
class IslandLyricService {
  IslandLyricService._();

  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/island_lyric',
  );

  /// Shizuku 绕过焦点通知白名单的通道（授权探测）。
  static const MethodChannel _shizukuChannel = MethodChannel(
    'com.feiniu.music/island_lyric_shizuku',
  );

  /// 探测 Shizuku 授权状态：服务运行且权限已授予。未授权时会拉起系统授权弹窗。
  /// 用于「Shizuku 绕过白名单」开关打开前的授权检查。失败按未授权处理。
  static Future<bool> checkShizukuGranted() async {
    try {
      final ok = await _shizukuChannel.invokeMethod<bool>('checkAvailable');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到 MIUI/HyperOS 息屏通知动画设置页（供「息屏歌词」提示使用）。
  /// 无 root 时通过显式 Intent 启动；目标组件不存在 / 未导出时返回 false。
  static Future<bool> openAodSettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openAodSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 当前设备是否 HyperOS/MIUI（用于「息屏通知设置」跳转行仅在 HyperOS 显示）。
  ///
  /// 判定：MIUI 系统包 [com.miui.aod] 存在即视为小米 HyperOS 系设备。
  /// 结果缓存（跨次调用不变），调用失败按非 HyperOS 处理。
  static bool? _isHyperOs;
  static Future<bool> isHyperOs() async {
    if (_isHyperOs != null) return _isHyperOs!;
    try {
      final ok = await _channel.invokeMethod<bool>('isHyperOs');
      _isHyperOs = ok ?? false;
    } catch (_) {
      _isHyperOs = false;
    }
    return _isHyperOs!;
  }

  /// 灵动岛 / 焦点通知能力探测结果。
  ///
  /// - [supportIsland]：`persist.sys.feature.island`，当前 OS 是否支持岛功能
  ///   （岛渲染为 OS3 特有能力）；
  /// - [focusProtocol]：`notification_focus_protocol`，1=OS1 焦点通知模板、
  ///   2=OS2 焦点通知模板、3=OS3 小米超级岛通知模板；
  /// - [focusPermission]：`canShowFocus`，当前应用焦点通知权限是否开启；
  /// - [focusEnabled]：[focusProtocol]>=2（OS2/OS3 均支持焦点通知）&&
  ///   [focusPermission]，即当前设备上「焦点通知」模式是否可用。
  ///
  /// 探测失败按「不支持」处理（安全降级，隐藏对应开关）。
  static IslandCapabilities? _capabilities;
  static Future<IslandCapabilities> queryCapabilities() async {
    if (_capabilities != null) return _capabilities!;
    try {
      final raw = await _channel.invokeMapMethod<Object, Object>(
        'queryCapabilities',
      );
      _capabilities = IslandCapabilities.fromMap(raw ?? const {});
    } catch (_) {
      _capabilities = IslandCapabilities.none;
    }
    return _capabilities!;
  }

  /// 测试专用：清空能力探测缓存，供测试重复探测。
  @visibleForTesting
  static void resetCapabilitiesForTest() {
    _capabilities = null;
  }

  /// 测试专用：清空 HyperOS 探测缓存，供测试重复探测。
  @visibleForTesting
  static void resetDeviceProbeForTest() {
    _isHyperOs = null;
  }

  /// 进度更新节流：同一首歌内，两次进度驱动发送的最小间隔。
  static const Duration _progressThrottle = Duration(seconds: 1);

  /// 测试模式模拟发送间隔。
  static const Duration _testModeInterval = Duration(milliseconds: 800);

  /// 每帧最大字符数（最多一次显示 10 个字）：超过该长度智能截断拆帧，
  /// 避免焦点通知单侧文本被系统中间截断。每帧再对半分配到左右两侧。
  static const int _frameChars = 10;

  /// 实时通知（shortCriticalText）单侧最多显示 7 个字：超过则智能截断，
  /// 空格优先断点，取首帧作为灵动岛右侧歌词。
  static const int _liveMaxChars = 7;

  static bool _started = false;
  static String? _lastLyricLine;
  static bool _lastIsPlaying = false;
  static DateTime? _lastProgressSent;
  static Timer? _testModeTimer;
  static int _testTick = 0;
  static int _lastFrameIndex = 0;

  /// 上次发送用的通知类型。切换类型时即使歌词未变也要重发（让实时/焦点切换即时生效）。
  static int _lastNotificationType = IslandLyricSettings.typeLive;

  /// 上次发送用的绕过状态。切换绕过开关时即使歌词未变也要重发（让绕过即时生效）。
  static bool _lastBypassFocusLimit = false;

  // 封面相关状态
  static String? _lastSongId;
  static String? _lastCoverId;
  static String? _lastCoverPath;

  /// 幂等启动。默认监听 [LyricsService.instance] 与 [PlayerService.instance]。
  static void start() {
    if (_started) return;
    _started = true;
    IslandLyricSettings.enabled.addListener(_onSettingsChanged);
    IslandLyricSettings.testMode.addListener(_onSettingsChanged);
    IslandLyricSettings.aodLyrics.addListener(_onSettingsChanged);
    IslandLyricSettings.notificationType.addListener(_onSettingsChanged);
    IslandLyricSettings.bypassFocusLimit.addListener(_onSettingsChanged);
    LyricsService.instance.currentLineText.addListener(_onLyricLineChanged);
    PlayerService.instance.isPlaying.addListener(_onPlayingChanged);
    PlayerService.instance.position.addListener(_onPositionChanged);
    _syncTestMode();
    _syncLyric();
  }

  /// 测试专用：停止监听并复位。
  @visibleForTesting
  static void resetForTest() {
    if (!_started) return;
    IslandLyricSettings.enabled.removeListener(_onSettingsChanged);
    IslandLyricSettings.testMode.removeListener(_onSettingsChanged);
    IslandLyricSettings.aodLyrics.removeListener(_onSettingsChanged);
    IslandLyricSettings.notificationType.removeListener(_onSettingsChanged);
    IslandLyricSettings.bypassFocusLimit.removeListener(_onSettingsChanged);
    LyricsService.instance.currentLineText.removeListener(_onLyricLineChanged);
    PlayerService.instance.isPlaying.removeListener(_onPlayingChanged);
    PlayerService.instance.position.removeListener(_onPositionChanged);
    _started = false;
    _stopTestTimer();
    _lastLyricLine = null;
    _lastIsPlaying = false;
    _lastProgressSent = null;
    _lastFrameIndex = 0;
    _lastNotificationType = IslandLyricSettings.typeLive;
    _lastBypassFocusLimit = false;
    _lastSongId = null;
    _lastCoverId = null;
    _lastCoverPath = null;
  }

  /// 核心决策：是否应向灵动岛推送歌词。
  @visibleForTesting
  static bool shouldShow({
    required bool enabled,
    required bool isPlaying,
    required String? lyricLine,
  }) {
    if (!enabled) return false;
    if (!isPlaying) return false;
    if (lyricLine == null || lyricLine.trim().isEmpty) return false;
    return true;
  }

  /// 歌词行是否值得更新（去重）：上一行与当前行不同则更新。
  @visibleForTesting
  static bool shouldUpdate({required String? previous, required String? next}) {
    if (next == null || next.trim().isEmpty) return false;
    return previous != next;
  }

  /// 测试模式：生成一条模拟歌词通知的 payload（纯函数，确定性）。
  ///
  /// - 歌词行在 [lyricCount] 行内循环（`测试歌词 1/4` ... `测试歌词 4/4`）；
  /// - 进度随 tick 递增，到 100 归零循环；
  /// - 始终 [isPlaying]=true，模拟「暂停/不播放」下仍在上岛。
  @visibleForTesting
  static Map<String, Object> simulateTestPayload({
    required int tick,
    required int lyricCount,
  }) {
    final lineIndex = tick % lyricCount;
    // 进度随 tick 递增：每行歌词推进 100/lyricCount 个百分点，到顶后归零循环
    final step = (100 / lyricCount).round();
    final progress = ((tick % 100) * step) % 100;
    final lyric = '测试歌词 ${lineIndex + 1}/$lyricCount';
    final split = splitLyricForIsland(lyric);
    return {
      'lyric': split.right,
      'leftLyric': split.left,
      'title': '灵动岛测试',
      'artist': 'FeiNiu Music',
      'isPlaying': true,
      'progress': progress,
      'positionMs': progress * 1000, // 模拟进度对应位置
      'durationMs': 100000, // 100s
      'showProgress': true,
      // 测试模式同样尊重当前通知类型（实时/焦点），便于分别验证两条路径
      'notificationType': IslandLyricSettings.notificationType.value,
      'bypassFocusLimit': IslandLyricSettings.bypassFocusLimit.value,
    };
  }

  // ---- 测试模式 ----

  static void _onSettingsChanged() {
    _syncTestMode();
    _syncLyric();
  }

  static void _syncTestMode() {
    final testMode = IslandLyricSettings.testMode.value;
    if (testMode) {
      _startTestTimer();
    } else {
      _stopTestTimer();
    }
  }

  static void _startTestTimer() {
    if (_testModeTimer != null) return;
    _testModeTimer = Timer.periodic(_testModeInterval, (_) {
      final payload = simulateTestPayload(tick: _testTick++, lyricCount: 4);
      _lastLyricLine = payload['lyric'] as String;
      _lastIsPlaying = true;
      _channel.invokeMethod('update', payload);
    });
  }

  static void _stopTestTimer() {
    _testModeTimer?.cancel();
    _testModeTimer = null;
    _testTick = 0;
    if (_lastLyricLine != null || _lastIsPlaying) {
      _lastLyricLine = null;
      _lastIsPlaying = false;
      _channel.invokeMethod('hide');
    }
  }

  // ---- 大岛歌词分割 ----

  /// 分割结果：左侧放前半段，右侧放后半段，拼接成完整歌词。
  ///
  /// 优先在空格/词边界分割（避免把短语从中间切开），两侧均去掉首尾空格，
  /// 防止尾随空格导致系统侧滚动/错位。无空格时按字符数均分。
  @visibleForTesting
  static ({String left, String right}) splitLyricForIsland(String lyric) {
    final trimmed = lyric.trim();
    if (trimmed.isEmpty) return (left: '', right: '');
    final chars = trimmed.runes.toList();

    // 优先在空格处断：找中间段里最近的空格，避免切开短语
    var cut = (chars.length / 2).ceil();
    // 在 [cut/2, cut] 区间内找最后一个空格，使两侧更均衡
    for (var j = cut; j > 0; j--) {
      if (chars[j - 1] == 0x20) {
        cut = j;
        break;
      }
    }
    // 找不到空格则按字符均分
    if (cut <= 0 || cut >= chars.length) {
      cut = (chars.length / 2).ceil();
    }

    final left = String.fromCharCodes(chars.take(cut)).trim();
    final right = String.fromCharCodes(chars.skip(cut)).trim();
    // 若右侧为空但左侧有值（极端情况），把整行放右侧
    if (right.isEmpty && left.isNotEmpty) {
      return (left: '', right: trimmed);
    }
    return (left: left, right: right);
  }

  /// 是否应发送/更新封面（纯函数）。
  ///
  /// 仅在切歌或封面 id 变化时返回 true，避免同一首歌反复下载封面。
  /// 无封面 id 的歌曲恒返回 false（不发封面）。
  @visibleForTesting
  static bool shouldSendCover({
    required String? prevSongId,
    required String? prevCoverId,
    required String? newSongId,
    required String? newCoverId,
  }) {
    if (newCoverId == null || newCoverId.isEmpty) return false;
    if (prevSongId == newSongId && prevCoverId == newCoverId) return false;
    return true;
  }

  /// 分隔符 rune 集合：空格、连字符、连接号、间隔号等。
  ///
  /// 拆帧时作为智能断点（避免把词从中间切开），且最终显示时被过滤掉
  /// （不留存在帧内），避免灵动岛/通知上出现孤立的空格或连字符。
  static const Set<int> _separators = {
    0x20, // 空格
    0x2D, // - 连字符
    0x2013, // – en dash
    0x2014, // — em dash
    0x00B7, // · 间隔号
    0x30FB, // ・ 片假名中黑点
    0x7E, // ~
    0xFF5E, // ～
  };

  static bool _isSeparator(int rune) => _separators.contains(rune);

  /// 超长歌词智能拆帧（纯函数）。
  ///
  /// 按 [frameChars] 字符数拆帧，每帧不超过该容量。优先在空格/词边界断，
  /// 避免把中文短语或短英文单词从中间切开；单个超长 ASCII 单词本身必须被切
  /// 时仍切成多帧（每帧不超容量）。短歌词单帧，空歌词无帧。所有帧拼接 =
  /// 完整歌词（无丢失）。
  ///
  /// 分隔符（空格、连字符、间隔号等 [_separators]）作为断点使用，并在帧内
  /// 被过滤：帧首尾和帧中的分隔符都不保留，避免灵动岛/通知上出现孤立
  /// 分隔符。所有帧去掉分隔符后拼接 = 原歌词去掉分隔符（无内容丢失）。
  ///
  /// 用途：焦点通知单侧文本超宽会被系统中间截断（隐藏中间字），拆帧后每帧
  /// 用满左右两侧、按行节奏切换，避免截断。
  @visibleForTesting
  static List<String> chunkLyric(String lyric, {required int frameChars}) {
    if (lyric.isEmpty) return const [];
    final chars = lyric.runes.toList();

    final buildFrame = (int start, int end) {
      // 过滤帧内的分隔符后返回文本；全是分隔符时返回空
      final buf = StringBuffer();
      for (var k = start; k < end; k++) {
        if (!_isSeparator(chars[k])) {
          buf.writeCharCode(chars[k]);
        }
      }
      return buf.toString();
    };

    if (chars.length <= frameChars) {
      final text = buildFrame(0, chars.length);
      return text.isEmpty ? const [] : [text];
    }

    final frames = <String>[];
    var i = 0;
    while (i < chars.length) {
      var end = (i + frameChars).clamp(0, chars.length);
      // 智能断点：优先在最近的分隔符/词边界断，避免把词从中间切开
      if (end < chars.length) {
        var boundary = -1;
        for (var j = end; j > i; j--) {
          if (_isSeparator(chars[j - 1])) {
            boundary = j;
            break;
          }
        }
        if (boundary > i && boundary < end) {
          end = boundary;
        }
      }
      // 跳过段首分隔符（分隔符作为断点，不留在帧首）
      var start = i;
      while (start < end && _isSeparator(chars[start])) {
        start++;
      }
      // 跳过段尾分隔符（不留在帧尾，避免系统侧滚动/错位）
      while (end > start && _isSeparator(chars[end - 1])) {
        end--;
      }

      if (end > start) {
        final text = buildFrame(start, end);
        if (text.isNotEmpty) {
          frames.add(text);
        }
      }
      i = end > i ? end : i + 1;
    }
    return frames;
  }

  /// 当前播放位置对应的帧索引（纯函数）。
  ///
  /// 在行时间窗口 [start, end] 内按 [frameCount] 等分，位置落在哪一段就返回
  /// 哪一帧；位置在行开始前返回 0，行结束后返回最后一帧。[lineEndMs] 为 null
  /// 或 [frameCount]≤1 时恒返回 0。
  @visibleForTesting
  static int frameIndexForPosition({
    required int frameCount,
    required int lineStartMs,
    required int? lineEndMs,
    required int positionMs,
  }) {
    if (lineEndMs == null || frameCount <= 1) return 0;
    if (positionMs <= lineStartMs) return 0;
    if (positionMs >= lineEndMs) return frameCount - 1;
    final window = lineEndMs - lineStartMs;
    final ratio = (positionMs - lineStartMs) / window;
    final index = (ratio * frameCount).floor();
    return index.clamp(0, frameCount - 1);
  }

  /// 基于逐字时间戳的帧索引（纯函数）。
  ///
  /// 逐字歌词每字有精确 [LyricWord.start]/[end] 时间戳。当前播放位置
  /// 落在哪个字，就把该字对应到 [frames]（按字符切好的帧）里的哪一帧。
  ///
  /// 相比按行窗口等分的 [frameIndexForPosition]，字级时间戳能精确同步
  /// 演唱进度——不会出现"等分错位导致唱完了才翻帧"的问题。
  ///
  /// 无逐字时间戳 / 单帧时退回 [frameIndexForPosition] 的等分逻辑。
  @visibleForTesting
  static int frameIndexForPositionWithWords({
    required List<String> frames,
    required List<fl.LyricWord>? words,
    required int lineStartMs,
    required int? lineEndMs,
    required int positionMs,
  }) {
    if (frames.length <= 1) return 0;
    if (words == null || words.isEmpty) {
      return frameIndexForPosition(
        frameCount: frames.length,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
        positionMs: positionMs,
      );
    }

    // 当前播放位置对应的字下标：最后一个 start ≤ positionMs 的字。
    var currentWord = -1;
    for (var i = 0; i < words.length; i++) {
      if (words[i].start.inMilliseconds <= positionMs) {
        currentWord = i;
      } else {
        break;
      }
    }
    if (currentWord < 0) return 0;
    if (currentWord >= words.length - 1) return frames.length - 1;

    // 把字词文本拼接，用其累积字符长度映射到 frames 的字符边界。
    // 帧按字符切：累计到当前字的字符数占总字符数的比例 → 帧索引。
    final totalChars = words.fold<int>(
      0,
      (sum, w) => sum + w.text.runes.length,
    );
    if (totalChars <= 0) {
      return frameIndexForPosition(
        frameCount: frames.length,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
        positionMs: positionMs,
      );
    }
    var charsBefore = 0;
    for (var i = 0; i <= currentWord; i++) {
      charsBefore += words[i].text.runes.length;
    }
    final ratio = charsBefore / totalChars;
    final index = (ratio * frames.length).floor();
    return index.clamp(0, frames.length - 1);
  }

  // ---- 监听回调 ----

  static void _onLyricLineChanged() => _syncLyric();
  static void _onPlayingChanged() => _syncLyric();

  static void _onPositionChanged() {
    final enabled = IslandLyricSettings.enabled.value;
    if (!enabled) return;
    final isPlaying = PlayerService.instance.isPlaying.value;
    final lyricLine = LyricsService.instance.currentLineText.value;
    if (!shouldShow(
      enabled: true,
      isPlaying: isPlaying,
      lyricLine: lyricLine,
    )) {
      return;
    }
    if (_lastLyricLine == null) return; // 当前未在显示，无需刷进度

    // 超长歌词（多帧）：按播放位置推进帧，帧翻转时重发。实时/焦点都适用——
    // 这样「旧梦前尘 一去不回」这类长行会随进度推进显示后半段。
    // 有逐字时间戳时用字级进度精确推进，避免等分错位导致"唱完了才翻帧"。
    final isLive =
        IslandLyricSettings.notificationType.value ==
        IslandLyricSettings.typeLive;
    final frames = chunkLyric(
      _lastLyricLine!,
      frameChars: isLive ? _liveMaxChars : _frameChars,
    );
    if (frames.length > 1) {
      final (startMs, endMs, words) = _currentLineWords();
      final positionMs = PlayerService.instance.position.value.inMilliseconds;
      final frame = frameIndexForPositionWithWords(
        frames: frames,
        words: words,
        lineStartMs: startMs,
        lineEndMs: endMs,
        positionMs: positionMs,
      );
      if (frame != _lastFrameIndex) {
        _lastFrameIndex = frame;
        _sendUpdate();
        return;
      }
    }

    // 实时通知：单帧（短行）歌词没变就不更新，避免进度驱动高频重发。
    if (isLive) {
      return;
    }

    final now = DateTime.now();
    if (_lastProgressSent != null &&
        now.difference(_lastProgressSent!) < _progressThrottle) {
      return;
    }
    _lastProgressSent = now;
    _sendUpdate();
  }

  /// 汇总当前状态并驱动原生层（歌词行 / 播放状态 / 开关变化时调用）。
  static void _syncLyric() {
    final enabled = IslandLyricSettings.enabled.value;
    final isPlaying = PlayerService.instance.isPlaying.value;
    final lyricLine = LyricsService.instance.currentLineText.value;

    if (!shouldShow(
      enabled: enabled,
      isPlaying: isPlaying,
      lyricLine: lyricLine,
    )) {
      if (_lastLyricLine != null || _lastIsPlaying) {
        _lastLyricLine = null;
        _lastIsPlaying = false;
        _lastProgressSent = null;
        _lastFrameIndex = 0;
        _lastNotificationType = IslandLyricSettings.typeLive;
        _lastBypassFocusLimit = false;
        _channel.invokeMethod('hide');
      }
      return;
    }

    if (shouldUpdate(previous: _lastLyricLine, next: lyricLine)) {
      _lastLyricLine = lyricLine;
      _lastIsPlaying = isPlaying;
      _lastFrameIndex = 0;
      _lastNotificationType = IslandLyricSettings.notificationType.value;
      _lastBypassFocusLimit = IslandLyricSettings.bypassFocusLimit.value;
      _sendUpdate();
      _maybeDownloadCover();
      return;
    }

    // 歌词未变但通知类型切换：当前正在显示时需立即用新类型重发，
    // 否则实时/焦点切换在播放中不会生效（仅对当前行生效）。
    if (_lastNotificationType != IslandLyricSettings.notificationType.value) {
      _lastNotificationType = IslandLyricSettings.notificationType.value;
      _lastBypassFocusLimit = IslandLyricSettings.bypassFocusLimit.value;
      _sendUpdate();
      return;
    }

    // 歌词与类型未变但绕过开关切换：焦点通知下立即用新绕过状态重发，
    // 否则绕过开关在播放中不会即时生效。
    if (_lastBypassFocusLimit != IslandLyricSettings.bypassFocusLimit.value) {
      _lastBypassFocusLimit = IslandLyricSettings.bypassFocusLimit.value;
      _sendUpdate();
    }
  }

  /// 封面变化时异步下载封面到本地文件，下载完成后随下次 update 发送。
  static Future<void> _maybeDownloadCover() async {
    final song = PlayerService.instance.currentSong.value;
    final coverId = song?.coverId;
    if (!shouldSendCover(
      prevSongId: _lastSongId,
      prevCoverId: _lastCoverId,
      newSongId: song?.id,
      newCoverId: coverId,
    )) {
      return;
    }
    _lastSongId = song?.id;
    _lastCoverId = coverId;
    _lastCoverPath = null;

    if (coverId == null || coverId.isEmpty) return;

    final path = await CoverLocalCache.downloadToLocal(
      coverId,
      updatedAt: song?.updatedAt,
    );
    if (path == null) return;
    _lastCoverPath = path;
    // 封面就绪后补发一次 update（带 coverPath），让原生层刷新左侧封面
    if (_started && _lastLyricLine != null) {
      _sendUpdate();
    }
  }

  /// 向原生层发送完整当前状态（歌词 + 歌曲信息 + 播放进度）。
  ///
  /// 焦点通知：拆帧后每帧对半分配到左右两侧（leftLyric = 帧前半、
  /// lyric = 帧后半），每帧用满左右两侧且每侧不超系统容量，避免单侧文本
  /// 被系统中间截断。
  /// 实时通知：短歌词单帧（整行）；超长歌词不拆帧，完整歌词行给
  /// shortCriticalText（系统侧自动滚动适配）。
  static void _sendUpdate() {
    final player = PlayerService.instance;
    final song = player.currentSong.value;
    final lyricLine = _lastLyricLine;
    if (lyricLine == null) return;

    final isLive =
        IslandLyricSettings.notificationType.value ==
        IslandLyricSettings.typeLive;
    // 超长歌词按容量智能截断（空格优先断点）：实时 7 字、焦点 10 字。
    // 多帧时按播放位置推进（_lastFrameIndex，由 _onPositionChanged 更新），
    // 让「旧梦前尘 一去不回」这类长行能推进显示后半段。
    final frames = chunkLyric(
      lyricLine,
      frameChars: isLive ? _liveMaxChars : _frameChars,
    );
    String frame;
    if (frames.isEmpty) {
      frame = lyricLine;
    } else {
      final frameIndex = frames.length <= 1
          ? 0
          : _lastFrameIndex.clamp(0, frames.length - 1);
      frame = frames[frameIndex];
    }
    final split = splitLyricForIsland(frame);

    final payload = buildUpdatePayload(
      fullLyric: frame,
      title: song?.title ?? '',
      artist: song?.artistDisplayName ?? '',
      isPlaying: player.isPlaying.value,
      positionMs: player.position.value.inMilliseconds,
      durationMs: song?.durationMs ?? 0,
      showProgress: IslandLyricSettings.showProgress.value,
      coverPath: _lastCoverPath,
      aodLyrics: IslandLyricSettings.aodLyrics.value,
    );
    // 左右分割后的实际显示内容（覆盖 payload 里由 fullLyric 派生的 lyric/leftLyric）
    payload['lyric'] = split.right;
    payload['leftLyric'] = split.left;

    // 记录本次发送用的通知类型（供切换类型时即时重发判定）
    _lastNotificationType = IslandLyricSettings.notificationType.value;
    // 记录本次发送用的绕过状态（供切换绕过开关时即时重发判定）
    _lastBypassFocusLimit = IslandLyricSettings.bypassFocusLimit.value;

    _channel.invokeMethod('update', payload);
  }

  /// 构建发送给原生层的 update payload（纯函数，可测）。
  ///
  /// [fullLyric] = 完整当前歌词帧（供息屏 aodTitle / 通知标题使用）。
  /// 返回的 map 含 lyric/leftLyric，但由调用方按 split 结果覆盖为左右半。
  @visibleForTesting
  static Map<String, Object?> buildUpdatePayload({
    required String fullLyric,
    required String title,
    required String artist,
    required bool isPlaying,
    required int positionMs,
    required int durationMs,
    required bool showProgress,
    required String? coverPath,
    required bool aodLyrics,
  }) {
    final split = splitLyricForIsland(fullLyric);
    return {
      'fullLyric': fullLyric,
      'lyric': split.right,
      'leftLyric': split.left,
      'title': title,
      'artist': artist,
      'isPlaying': isPlaying,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'showProgress': showProgress,
      'coverPath': coverPath,
      'aodLyrics': aodLyrics,
      // 通知类型：实时通知（无 root）还是焦点通知
      'notificationType': IslandLyricSettings.notificationType.value,
      // 焦点通知下是否用 Shizuku 绕过系统白名单（仅 typeFocus 生效）
      'bypassFocusLimit': IslandLyricSettings.bypassFocusLimit.value,
    };
  }

  /// 当前歌词行的时间窗口 + 逐字时间戳。无歌词模型时返回兜底。
  static (int, int?, List<fl.LyricWord>?) _currentLineWords() {
    final model = LyricsService.instance.snapshot.value.model;
    final index = LyricsService.instance.controller.activeIndexNotifiter.value;
    if (model == null || index < 0 || index >= model.lines.length) {
      return (0, null, null);
    }
    final line = model.lines[index];
    return (line.start.inMilliseconds, line.end?.inMilliseconds, line.words);
  }
}

/// 灵动岛 / 焦点通知能力探测结果（来自原生层 [MainActivity.queryIslandCapabilities]）。
class IslandCapabilities {
  const IslandCapabilities({
    required this.supportIsland,
    required this.focusProtocol,
    required this.focusPermission,
    required this.focusEnabled,
    required this.androidSdk,
  });

  /// 探测失败 / 原生层不可用时的安全兜底（全部按不支持处理）。
  static const IslandCapabilities none = IslandCapabilities(
    supportIsland: false,
    focusProtocol: 0,
    focusPermission: false,
    focusEnabled: false,
    androidSdk: 0,
  );

  /// 当前 OS 是否支持岛功能（`persist.sys.feature.island`）。
  final bool supportIsland;

  /// 焦点通知协议版本：1=OS1、2=OS2、3=OS3 小米超级岛（OS2/OS3 均支持焦点通知）。
  final int focusProtocol;

  /// 当前应用焦点通知权限是否开启（`canShowFocus`）。
  final bool focusPermission;

  /// 当前设备上「焦点通知」模式是否可用（focusProtocol>=2 且权限开启）。
  final bool focusEnabled;

  /// Android 版本号（SDK_INT）：实时通知（实况通知）需 Android 16（API 36+）。
  final int androidSdk;

  /// 当前设备上「实时通知」模式是否可用（Android 16+）。
  bool get liveEnabled => androidSdk >= 36;

  /// 解析原生层返回的 map。缺字段 / 类型不符按默认（不支持）处理。
  factory IslandCapabilities.fromMap(Map<Object, Object> raw) {
    bool readBool(Object? v) => v is bool && v;
    int readInt(Object? v) => v is num ? v.toInt() : 0;
    final supportIsland = readBool(raw['supportIsland']);
    final focusProtocol = readInt(raw['focusProtocol']);
    final focusPermission = readBool(raw['focusPermission']);
    return IslandCapabilities(
      supportIsland: supportIsland,
      focusProtocol: focusProtocol,
      focusPermission: focusPermission,
      focusEnabled:
          readBool(raw['focusEnabled']) ||
          (focusProtocol >= 2 && focusPermission),
      androidSdk: readInt(raw['androidSdk']),
    );
  }
}

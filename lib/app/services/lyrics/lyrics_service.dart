import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import '../player_service.dart';
import '../../state/settings_lyric_auto_search.dart';
import '../../state/settings_lyric_companion.dart';
import '../../state/song_state.dart';
import '../song_match/song_match_service.dart';
import 'lyric_companion_service.dart';
import 'lyrics_parser.dart';
import 'lyrics_repository.dart';
import 'lyricon_service.dart';
import 'meizu_lyrics_service.dart';

enum LyricsLoadStatus { idle, loading, loaded, empty, failed }

/// 是否包含可用于逐字高亮的字词级时间轴。
///
/// 单个整行 token 不属于逐字歌词；至少一行有两个及以上时间片才启用逐字效果。
bool hasWordLevelLyrics(fl.LyricModel? model) {
  return model?.lines.any((line) => (line.words?.length ?? 0) >= 2) ?? false;
}

@visibleForTesting
bool shouldReloadStaleLyricsSearch({
  required int requestSequence,
  required int currentSequence,
  required String? searchedLyrics,
  required String songId,
  required String? currentSongId,
}) {
  return requestSequence != currentSequence &&
      searchedLyrics != null &&
      searchedLyrics.trim().isNotEmpty &&
      currentSongId == songId;
}

class LyricsSnapshot {
  final LyricsLoadStatus status;
  final SongEntity? song;
  final fl.LyricModel? model;
  final Object? error;

  const LyricsSnapshot({
    required this.status,
    required this.song,
    required this.model,
    required this.error,
  });

  factory LyricsSnapshot.idle() {
    return const LyricsSnapshot(
      status: LyricsLoadStatus.idle,
      song: null,
      model: null,
      error: null,
    );
  }

  LyricsSnapshot copyWith({
    LyricsLoadStatus? status,
    SongEntity? song,
    Object? error,
    fl.LyricModel? model,
    bool clearModel = false,
  }) {
    return LyricsSnapshot(
      status: status ?? this.status,
      song: song ?? this.song,
      model: clearModel ? null : (model ?? this.model),
      error: error,
    );
  }
}

class LyricsService {
  static final LyricsService instance = LyricsService._internal();

  static const String _prefsLyriconEnabled = 'lyrics_lyricon_enabled';
  static const String _prefsLyriconForceKaraoke =
      'lyrics_lyricon_force_karaoke';
  static const String _prefsLyriconHideTranslation =
      'lyrics_lyricon_hide_translation';
  static const String _prefsMeizuLyrics = 'lyrics_meizu_enabled';
  static const String _prefsViewForceKaraoke = 'lyrics_view_force_karaoke';
  static const String _prefsViewInactiveColor = 'lyrics_view_inactive_color';
  static const String _prefsViewActiveColor = 'lyrics_view_active_color';
  static const String _prefsViewHighlightColor = 'lyrics_view_highlight_color';

  final LyricsRepository _repo = LyricsRepository();
  final PlayerService _player = PlayerService.instance;
  final LyricController controller = LyricController();
  final ValueNotifier<LyricsSnapshot> snapshot = ValueNotifier(
    LyricsSnapshot.idle(),
  );
  final ValueNotifier<String?> currentLineText = ValueNotifier(null);
  final ValueNotifier<int> viewSettingsTick = ValueNotifier(0);

  /// 歌词页自定义颜色的镜像，供播放页逐字歌词保持一致。
  final ValueNotifier<int?> viewInactiveColor = ValueNotifier(null);
  final ValueNotifier<int?> viewActiveColor = ValueNotifier(null);
  final ValueNotifier<int?> viewHighlightColor = ValueNotifier(null);
  late final snapshotSignal = signal(LyricsSnapshot.idle());
  late final viewSettingsTickSignal = signal(0);
  late final activeIndexSignal = signal(controller.activeIndexNotifiter.value);
  late final lyricModelSignal = signal(controller.lyricNotifier.value);
  late final isSelectingSignal = signal(controller.isSelectingNotifier.value);
  late final selectedIndexSignal = signal(
    controller.selectedIndexNotifier.value,
  );

  int _loadSeq = 0;
  Timer? _lyriconPosTimer;
  bool _lyriconFlushInFlight = false;
  int _lastLyriconPositionMs = -1;
  bool _lyriconEnabled = false;
  bool _lyriconForceKaraoke = false;
  bool _lyriconHideTranslation = false;
  bool _meizuEnabled = false;
  int _meizuLastIndex = -1;
  bool _viewForceKaraoke = false;

  LyricsService._internal() {
    snapshot.addListener(() => snapshotSignal.value = snapshot.value);
    viewSettingsTick.addListener(
      () => viewSettingsTickSignal.value = viewSettingsTick.value,
    );
    controller.activeIndexNotifiter.addListener(
      () => activeIndexSignal.value = controller.activeIndexNotifiter.value,
    );
    controller.activeIndexNotifiter.addListener(_onActiveIndexChanged);
    controller.lyricNotifier.addListener(
      () => lyricModelSignal.value = controller.lyricNotifier.value,
    );
    controller.isSelectingNotifier.addListener(
      () => isSelectingSignal.value = controller.isSelectingNotifier.value,
    );
    controller.selectedIndexNotifier.addListener(
      () => selectedIndexSignal.value = controller.selectedIndexNotifier.value,
    );
    controller.setOnTapLineCallback((pos) {
      controller.stopSelection();
      _player.seek(pos);
    });
    _player.currentSong.addListener(_onSongChanged);
    _player.position.addListener(_onPositionChanged);
    _player.isPlaying.addListener(_onPlayingChanged);
    viewSettingsTick.addListener(_reloadViewColorPrefs);
    refreshSettings();
    _reloadViewColorPrefs();
    _onSongChanged();
  }

  void notifyViewSettingsChanged() {
    viewSettingsTick.value = viewSettingsTick.value + 1;
  }

  Future<void> _reloadViewColorPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    viewInactiveColor.value = prefs.getInt(_prefsViewInactiveColor);
    viewActiveColor.value = prefs.getInt(_prefsViewActiveColor);
    viewHighlightColor.value = prefs.getInt(_prefsViewHighlightColor);
  }

  Future<void> refreshSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _lyriconEnabled = prefs.getBool(_prefsLyriconEnabled) ?? false;
    _lyriconForceKaraoke = prefs.getBool(_prefsLyriconForceKaraoke) ?? false;
    _lyriconHideTranslation =
        prefs.getBool(_prefsLyriconHideTranslation) ?? false;
    _meizuEnabled = prefs.getBool(_prefsMeizuLyrics) ?? false;
    _viewForceKaraoke = prefs.getBool(_prefsViewForceKaraoke) ?? false;
    await LyricAutoSearchSettings.ensureLoaded();
    await LyriconService.setServiceEnabled(_lyriconEnabled);
    if (!_lyriconEnabled) {
      _stopLyriconPositionTimer();
    } else {
      _syncLyriconPositionTimer();
      final song = _player.currentSong.value;
      await _syncLyriconSong(song, snapshot.value.model);
    }
    if (!_meizuEnabled) {
      _meizuLastIndex = -1;
      await MeizuLyricsService.stopLyric();
    } else {
      _updateMeizuLyricForIndex(controller.activeIndexNotifiter.value);
    }
  }

  void _onSongChanged() {
    final song = _player.currentSong.value;
    _loadForSong(song);
  }

  void _onPositionChanged() {
    final pos = _player.position.value;
    controller.setProgress(pos);
    _syncLyriconPositionTimer();
  }

  void _onPlayingChanged() {
    unawaited(_syncLyriconPlaybackState());
    _syncLyriconPositionTimer();
  }

  void _onActiveIndexChanged() {
    _updateCurrentLineText(controller.activeIndexNotifiter.value);
    _updateMeizuLyricForIndex(controller.activeIndexNotifiter.value);
  }

  void reloadCurrentSong() {
    _loadForSong(_player.currentSong.value);
  }

  Future<void> _loadForSong(SongEntity? song) async {
    final seq = ++_loadSeq;
    snapshot.value = snapshot.value.copyWith(
      status: LyricsLoadStatus.loading,
      song: song,
      clearModel: true,
      error: null,
    );
    controller.lyricNotifier.value = null;
    currentLineText.value = null;

    if (song == null) {
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.empty,
        song: null,
        clearModel: true,
        error: null,
      );
      await _syncLyriconSong(null, null);
      if (_meizuEnabled) {
        _meizuLastIndex = -1;
        await MeizuLyricsService.stopLyric();
      }
      return;
    }

    try {
      await refreshSettings();
      var lrc = await _repo.loadLrc(song);
      if (seq != _loadSeq) return;

      if (lrc == null || lrc.trim().isEmpty) {
        // 无歌词：若开启「播放无歌词音乐时自动搜索」，通过服务端增强数据源搜索。
        // 需后端（FnMusicEnhance）可达。
        var searched = lrc;
        if (LyricAutoSearchSettings.enabled.value &&
            SongMatchService.instance.available) {
          searched = await _searchLyricForSong(song);
          if (seq != _loadSeq) {
            if (shouldReloadStaleLyricsSearch(
              requestSequence: seq,
              currentSequence: _loadSeq,
              searchedLyrics: searched,
              songId: song.id,
              currentSongId: _player.currentSong.value?.id,
            )) {
              unawaited(_loadForSong(song));
            }
            return;
          }
        }

        if (searched == null || searched.trim().isEmpty) {
          snapshot.value = snapshot.value.copyWith(
            status: LyricsLoadStatus.empty,
            song: song,
            clearModel: true,
            error: null,
          );
          await _syncLyriconSong(song, null);
          if (_meizuEnabled) {
            _meizuLastIndex = -1;
            await MeizuLyricsService.stopLyric();
          }
          return;
        }
        lrc = searched;
      }

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        songDuration: (song.durationMs == null)
            ? null
            : Duration(milliseconds: song.durationMs!),
        predictDuration: false,
        forceKaraoke: _viewForceKaraoke || _lyriconForceKaraoke,
      );
      if (kDebugMode) {
        final translationCount = model.lines
            .where((line) => (line.translation ?? '').trim().isNotEmpty)
            .length;
        debugPrint(
          '[Lyrics] parsed ${model.lines.length} lines, '
          '$translationCount translations for ${song.title}',
        );
      }
      controller.loadLyricModel(model);
      _updateCurrentLineText(controller.activeIndexNotifiter.value);
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.loaded,
        song: song,
        model: model,
        error: null,
      );
      await _syncLyriconSong(song, model);
      _updateMeizuLyricForIndex(controller.activeIndexNotifiter.value);
    } catch (e) {
      if (seq != _loadSeq) return;
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.failed,
        song: song,
        clearModel: true,
        error: e,
      );
      await _syncLyriconSong(song, null);
      if (_meizuEnabled) {
        _meizuLastIndex = -1;
        await MeizuLyricsService.stopLyric();
      }
    }
  }

  /// 通过数据源插件自动搜索歌曲歌词（「播放无歌词音乐时自动搜索」）。
  ///
  /// 命中后写入本地歌词缓存；「搜索到后自动回写到 NAS」开启且服务端增强
  /// （FnMusicEnhance）可用（已配置地址）时，再同步写入 NAS。
  /// 返回 LRC 文本；未命中返回 null。
  Future<String?> _searchLyricForSong(SongEntity song) async {
    try {
      final lyrics = await SongMatchService.instance.fetchLyrics(
        title: song.title,
        artist: song.artistDisplayName,
        album: song.albumDisplayName == '未知专辑' ? '' : song.albumDisplayName,
        duration: song.durationMs ?? 0,
      );
      if (lyrics == null || lyrics.trim().isEmpty) return null;

      // 命中歌词写入本地缓存（后续播放/搜索不再走网络）。
      await _repo.saveLrcToCache(song.id, lyrics);

      // 回写开关开启且服务端增强已配置地址时，同步写入 NAS。
      // 真正可达性由 saveLyrics 内部 HTTP 决定（失败已 try/catch 静默）。
      if (LyricAutoSearchSettings.writeBack.value &&
          LyricCompanionSettings.enabled.value &&
          LyricCompanionService.instance.available) {
        try {
          await LyricCompanionService.instance.saveLyrics(song.id, lyrics);
        } catch (e) {
          debugPrint('[Lyrics] ${song.title} 自动搜索歌词写入 NAS 失败: $e');
        }
      }
      return lyrics;
    } catch (e) {
      debugPrint('[Lyrics] ${song.title} 自动搜索歌词失败: $e');
      return null;
    }
  }

  void _updateCurrentLineText(int index) {
    final model = controller.lyricNotifier.value;
    if (model == null || model.lines.isEmpty) {
      currentLineText.value = null;
      return;
    }
    if (index < 0 || index >= model.lines.length) {
      currentLineText.value = null;
      return;
    }
    final text = model.lines[index].text.trim();
    currentLineText.value = text.isEmpty ? null : text;
  }

  Future<void> _syncLyriconPlaybackState() async {
    if (!_lyriconEnabled) return;
    await LyriconService.setPlaybackState(_player.isPlaying.value);
  }

  void _syncLyriconPositionTimer() {
    if (!_lyriconEnabled || !_player.isPlaying.value) {
      _stopLyriconPositionTimer();
      return;
    }
    _lyriconPosTimer ??= Timer.periodic(const Duration(milliseconds: 250), (
      _,
    ) async {
      if (_lyriconFlushInFlight) return;
      _lyriconFlushInFlight = true;
      try {
        await _flushLyriconPosition();
      } finally {
        _lyriconFlushInFlight = false;
      }
    });
  }

  void _stopLyriconPositionTimer() {
    _lyriconPosTimer?.cancel();
    _lyriconPosTimer = null;
  }

  Future<void> _flushLyriconPosition() async {
    if (!_lyriconEnabled || !_player.isPlaying.value) return;
    final ms = _player.position.value.inMilliseconds;
    if ((ms - _lastLyriconPositionMs).abs() < 150) return;
    _lastLyriconPositionMs = ms;
    await LyriconService.updatePosition(ms);
  }

  Future<void> _syncLyriconSong(SongEntity? song, fl.LyricModel? model) async {
    await LyriconService.setServiceEnabled(_lyriconEnabled);
    if (!_lyriconEnabled) return;
    if (song == null) return;
    await LyriconService.setSong(
      song,
      model,
      hideTranslation: _lyriconHideTranslation,
    );
    await LyriconService.setDisplayTranslation(!_lyriconHideTranslation);
    await LyriconService.setPlaybackState(_player.isPlaying.value);
  }

  void _updateMeizuLyricForIndex(int index) {
    if (!_meizuEnabled) return;
    final model = controller.lyricNotifier.value;
    if (model == null) {
      if (_meizuLastIndex != -1) {
        _meizuLastIndex = -1;
        MeizuLyricsService.stopLyric();
      }
      return;
    }
    if (index < 0 || index >= model.lines.length) {
      if (_meizuLastIndex != -1) {
        _meizuLastIndex = -1;
        MeizuLyricsService.stopLyric();
      }
      return;
    }
    if (_meizuLastIndex == index) return;
    _meizuLastIndex = index;
    final text = model.lines[index].text.trim();
    if (text.isEmpty) {
      MeizuLyricsService.stopLyric();
      return;
    }
    MeizuLyricsService.updateLyric(text);
  }
}

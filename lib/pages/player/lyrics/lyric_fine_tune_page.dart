import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/services/lyrics/lyric_companion_service.dart';
import '../../../app/services/lyrics/lyric_fine_tune_document.dart';
import '../../../app/services/lyrics/lyrics_repository.dart';
import '../../../app/services/lyrics/lyrics_service.dart';
import '../../../app/services/player_service.dart';
import '../../../app/state/song_state.dart';
import '../../../components/feedback/app_toast.dart';
import '../widgets/player_background.dart';

class LyricFineTunePage extends StatefulWidget {
  final SongEntity song;

  const LyricFineTunePage({super.key, required this.song});

  @override
  State<LyricFineTunePage> createState() => _LyricFineTunePageState();
}

class _LyricFineTunePageState extends State<LyricFineTunePage> {
  static const double _lineExtent = 76;

  final PlayerService _player = PlayerService.instance;
  final LyricsRepository _repository = LyricsRepository();
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _editor;
  late final Future<void> _completionHold;

  LyricFineTuneDocument _document = const LyricFineTuneDocument();
  Future<void> _serverWrites = Future<void>.value();
  bool _loading = true;
  bool _editing = false;
  bool _savingCache = false;
  bool _manualSelection = false;
  int? _selectedIndex;
  int? _forcedMatchIndex;
  int? _lastAutoIndex;
  double? _dragPositionMs;

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController();
    _completionHold = _player.acquireCompletionHold();
    _player.position.addListener(_onPlaybackChanged);
    _player.duration.addListener(_onPlaybackChanged);
    unawaited(_loadLyrics());
    unawaited(_startFromBeginning());
  }

  @override
  void dispose() {
    _player.position.removeListener(_onPlaybackChanged);
    _player.duration.removeListener(_onPlaybackChanged);
    _scrollController.dispose();
    _editor.dispose();
    unawaited(_completionHold.then((_) => _player.releaseCompletionHold()));
    super.dispose();
  }

  Duration get _duration {
    return _player.duration.value ??
        Duration(milliseconds: widget.song.durationMs ?? 0);
  }

  int? get _matchingIndex {
    final forced = _forcedMatchIndex;
    if (forced != null &&
        forced >= 0 &&
        forced < _document.lines.length &&
        _document.lines[forced].time == null) {
      return forced;
    }
    return _document.matchingIndex(_player.position.value, _duration);
  }

  int? get _activeTimedIndex {
    return _document.activeTimedIndex(_player.position.value);
  }

  int? get _autoScrollIndex => _matchingIndex ?? _activeTimedIndex;

  Future<void> _startFromBeginning() async {
    try {
      await _completionHold;
      if (!mounted || _player.currentSong.value?.id != widget.song.id) return;
      await _player.seek(Duration.zero);
      if (!mounted || _player.currentSong.value?.id != widget.song.id) return;
      await _player.play();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '开始播放失败：$error', type: ToastType.error);
    }
  }

  Future<void> _loadLyrics() async {
    try {
      final content = await _repository.loadLrc(widget.song) ?? '';
      if (!mounted) return;
      setState(() {
        _document = LyricFineTuneDocument.parse(content);
        _editor.text = _document.toLrc();
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMatchingLine();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.show(context, '读取歌词失败：$error', type: ToastType.error);
    }
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_manualSelection && !_editing) {
      _scrollToMatchingLine();
    }
  }

  void _scrollToMatchingLine() {
    final index = _autoScrollIndex;
    if (index == null ||
        index == _lastAutoIndex ||
        !_scrollController.hasClients) {
      return;
    }
    _lastAutoIndex = index;
    final target = (index * _lineExtent).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    unawaited(
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _selectCenteredLine() {
    if (!_scrollController.hasClients || _document.lines.isEmpty) return;
    final viewport = _scrollController.position.viewportDimension;
    final verticalPadding = _listPaddingForViewport(viewport);
    final index =
        ((_scrollController.offset + viewport / 2 - verticalPadding) /
                _lineExtent)
            .floor();
    setState(() {
      _selectedIndex = index.clamp(0, _document.lines.length - 1);
      _manualSelection = true;
    });
  }

  double _listPaddingForViewport(double viewport) {
    return ((viewport - _lineExtent) / 2).clamp(0.0, double.infinity);
  }

  void _recordCurrentTime() {
    final index = _matchingIndex;
    if (index == null) {
      AppToast.show(context, '当前时间区间没有待匹配歌词');
      return;
    }
    setState(() {
      _document = _document.setLineTime(index, _player.position.value);
      _forcedMatchIndex = null;
      _lastAutoIndex = null;
    });
    _scrollToMatchingLine();
  }

  void _copyPreviousTime() {
    final index = _matchingIndex;
    if (index == null) {
      AppToast.show(context, '当前时间区间没有待匹配歌词');
      return;
    }
    setState(() {
      _document = _document.setLineTime(
        index,
        _document.previousAnchorFor(index),
      );
      _forcedMatchIndex = null;
      _lastAutoIndex = null;
    });
    _scrollToMatchingLine();
  }

  Future<void> _playSelectedLine() async {
    final index = _selectedIndex;
    if (index == null) return;
    final line = _document.lines[index];
    await _player.seek(line.time ?? _document.previousAnchorFor(index));
    await _player.play();
  }

  Future<void> _matchSelectedLine() async {
    final index = _selectedIndex;
    if (index == null) return;
    final start = _document.previousAnchorFor(index);
    setState(() {
      _document = _document.clearLineTime(index);
      _forcedMatchIndex = index;
      _manualSelection = false;
      _selectedIndex = null;
      _lastAutoIndex = null;
    });
    await _player.seek(start);
    await _player.play();
    _scrollToMatchingLine();
  }

  void _clearTimes() {
    setState(() {
      _document = _document.clearTimes();
      _forcedMatchIndex = null;
      _lastAutoIndex = null;
    });
    AppToast.show(context, '已清除时间信息，尚未写入');
    _scrollToMatchingLine();
  }

  void _toggleEditing() {
    if (_editing) {
      final next = LyricFineTuneDocument.parse(_editor.text);
      setState(() {
        _document = next;
        _editing = false;
        _forcedMatchIndex = null;
        _manualSelection = false;
        _selectedIndex = null;
        _lastAutoIndex = null;
      });
      AppToast.show(context, '歌词已暂存到内存');
      _scrollToMatchingLine();
      return;
    }
    setState(() {
      _editor.text = _document.toLrc();
      _editing = true;
      _manualSelection = false;
      _selectedIndex = null;
    });
  }

  Future<void> _writeLyrics() async {
    if (_savingCache || _editing) return;
    final content = _document.toLrc();
    if (content.trim().isEmpty) {
      AppToast.show(context, '歌词内容为空', type: ToastType.error);
      return;
    }
    setState(() => _savingCache = true);
    try {
      await _repository.saveLrcToCache(
        widget.song.id,
        content,
        overwrite: true,
      );
      if (_player.currentSong.value?.id == widget.song.id) {
        LyricsService.instance.reloadCurrentSong();
      }
      if (mounted) {
        AppToast.show(context, '已写入缓存，正在同步服务端', type: ToastType.success);
      }
      _serverWrites = _serverWrites
          .catchError((_) {})
          .then(
            (_) => LyricCompanionService.instance.saveLyrics(
              widget.song.id,
              content,
              updateCache: false,
            ),
          )
          .then((_) {
            AppToast.showGlobal('歌词已同步到服务端', type: ToastType.success);
          })
          .catchError((Object error) {
            if (kDebugMode) {
              debugPrint('[LyricFineTunePage] server write failed: $error');
            }
            AppToast.showGlobal('歌词同步服务端失败：$error', type: ToastType.error);
          });
    } catch (error) {
      if (mounted) {
        AppToast.show(context, '写入歌词缓存失败：$error', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingCache = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          PlayerBackground(songSignal: _player.currentSongSignal),
          PlayerTheme(
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(context),
                  _buildSongInfo(context),
                  Expanded(child: _buildMainArea(context)),
                  _buildToolRow(context),
                  if (!_editing) _buildProgress(context),
                  if (!_editing) _buildTimingButtons(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
          Text(
            '歌词精校',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildSongInfo(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 3),
          Text(
            widget.song.artistDisplayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: _CompactToolButton(
                onPressed: _editing ? null : _clearTimes,
                label: '清除时间',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactToolButton(
                onPressed: _toggleEditing,
                label: _editing ? '暂存' : '编辑歌词',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactToolButton(
                onPressed: _editing || _savingCache ? null : _writeLyrics,
                label: '写入服务端',
                loading: _savingCache,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainArea(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: TextField(
          key: const ValueKey('lyric-fine-tune-editor'),
          controller: _editor,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
          decoration: const InputDecoration(
            hintText: '输入歌词，可保留 [00:00.00] 时间信息',
            border: OutlineInputBorder(),
          ),
        ),
      );
    }
    if (_document.lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词，请点击“编辑歌词”添加',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final matchingIndex = _matchingIndex;
    final activeTimedIndex = _activeTimedIndex;
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final verticalPadding = _listPaddingForViewport(
              constraints.maxHeight,
            );
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _manualSelection = true;
                  _selectCenteredLine();
                } else if (notification is ScrollUpdateNotification &&
                    _manualSelection) {
                  _selectCenteredLine();
                }
                return false;
              },
              child: ListView.builder(
                key: const ValueKey('lyric-fine-tune-list'),
                controller: _scrollController,
                padding: EdgeInsets.symmetric(vertical: verticalPadding),
                itemExtent: _lineExtent,
                itemCount: _document.lines.length,
                itemBuilder: (context, index) => _buildLyricLine(
                  context,
                  index,
                  matchingIndex,
                  activeTimedIndex,
                ),
              ),
            );
          },
        ),
        if (_manualSelection && _selectedIndex != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '从该行播放',
                      onPressed: _playSelectedLine,
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                    IconButton(
                      tooltip: '匹配该行时间',
                      onPressed: _matchSelectedLine,
                      icon: const Icon(Icons.my_location_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLyricLine(
    BuildContext context,
    int index,
    int? matchingIndex,
    int? activeTimedIndex,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final line = _document.lines[index];
    final matching = index == matchingIndex;
    final active = index == activeTimedIndex;
    final elapsed = line.time != null && _player.position.value > line.time!;
    final color = matching
        ? scheme.error
        : line.time == null
        ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
        : elapsed
        ? (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF90CAF9)
              : const Color(0xFF64B5F6))
        : (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF64B5F6)
              : const Color(0xFF174EA6));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, _manualSelection ? 128 : 20, 8),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              line.time == null ? '--:--' : _formatPosition(line.time!),
              style: TextStyle(
                color: color.withValues(alpha: 0.82),
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              line.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: matching || active ? 20 : 17,
                fontWeight: matching || active
                    ? FontWeight.w800
                    : FontWeight.w600,
                height: matching || active ? 1.35 : 1.15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalMs = _duration.inMilliseconds;
    final positionMs =
        (_dragPositionMs ?? _player.position.value.inMilliseconds.toDouble())
            .clamp(0.0, totalMs.toDouble());
    final max = totalMs > 0 ? totalMs.toDouble() : 1.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: scheme.onSurface,
              inactiveTrackColor: scheme.onSurfaceVariant.withValues(
                alpha: 0.25,
              ),
              thumbColor: scheme.onSurface,
            ),
            child: Slider(
              key: const ValueKey('lyric-fine-tune-progress'),
              value: positionMs,
              min: 0,
              max: max,
              onChanged: totalMs <= 0
                  ? null
                  : (value) {
                      setState(() => _dragPositionMs = value);
                    },
              onChangeEnd: totalMs <= 0
                  ? null
                  : (value) {
                      setState(() => _dragPositionMs = null);
                      unawaited(_seekAndPlay(value));
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatPosition(_player.position.value)),
                Text(_formatPosition(_duration)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _seekAndPlay(double positionMs) async {
    try {
      await _player.seek(Duration(milliseconds: positionMs.round()));
      if (!mounted || _player.currentSong.value?.id != widget.song.id) return;
      await _player.play();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(context, '跳转播放失败：$error', type: ToastType.error);
    }
  }

  Widget _buildTimingButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: SizedBox(
        height: 68,
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                key: const ValueKey('copy-previous-lyric-time'),
                onPressed: _copyPreviousTime,
                style: _fineTuneButtonStyle(),
                child: const Text(
                  '拷贝前一行时间',
                  maxLines: 1,
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const ValueKey('record-lyric-time'),
                onPressed: _recordCurrentTime,
                style: _fineTuneButtonStyle(),
                child: const Text(
                  '录入当前时间',
                  maxLines: 1,
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPosition(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60);
    final centiseconds = value.inMilliseconds.remainder(1000) ~/ 10;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}';
  }
}

class _CompactToolButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final bool loading;

  const _CompactToolButton({
    required this.onPressed,
    required this.label,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: _fineTuneButtonStyle(
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox.square(
                dimension: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Text(label, maxLines: 1, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

ButtonStyle _fineTuneButtonStyle({EdgeInsetsGeometry? padding}) {
  return FilledButton.styleFrom(
    padding: padding,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}

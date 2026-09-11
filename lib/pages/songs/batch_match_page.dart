import 'package:flutter/material.dart';

import '../../app/services/lyrics/lyrics_repository.dart';
import '../../app/services/song_match/backend_match_client.dart';
import '../../app/services/song_match/match_source_state.dart';
import '../../app/services/song_match/song_match_service.dart';
import '../../app/state/settings_match.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// 批量匹配数据页。
///
/// 两阶段流程：
/// 1. **确认页**：选择要匹配的字段（标题/歌手/专辑/年份/封面/歌词）、
///    写入模式（覆盖/填充）、是否逐首确认候选；
/// 2. **执行页**：按 [MatchSettings.concurrency] 并发执行后端数据源匹配，
///    自动取候选，上传封面、回传 NAS（updateTrackMetadata）。
class BatchMatchPage extends StatefulWidget {
  final List<SongEntity> songs;
  final bool autoStart;

  const BatchMatchPage({
    super.key,
    required this.songs,
    this.autoStart = false,
  });

  @override
  State<BatchMatchPage> createState() => _BatchMatchPageState();
}

class _BatchMatchPageState extends State<BatchMatchPage> {
  /// 阶段：confirm = 确认页；running = 执行中；done = 完成。
  String _phase = 'confirm';

  // 确认页选项（默认全不勾选，由用户选择要应用的字段）
  final Set<MatchField> _fields = {};
  MatchWriteMode _writeMode = MatchWriteMode.fill;

  /// 执行状态
  final Map<String, String> _status = {};
  int _completed = 0;
  int _success = 0;
  int _failed = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    for (final song in widget.songs) {
      _status[song.id] = 'pending';
    }
    if (widget.autoStart) {
      _fields.addAll(const {
        MatchField.title,
        MatchField.artist,
        MatchField.album,
        MatchField.year,
      });
      _writeMode = MatchWriteMode.overwrite;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  Future<void> _start() async {
    if (_running) return;
    if (_fields.isEmpty) {
      AppToast.show(context, '请至少选择一项匹配字段', type: ToastType.error);
      return;
    }
    setState(() {
      _phase = 'running';
      _running = true;
      _completed = 0;
      _success = 0;
      _failed = 0;
    });

    await MatchSettings.ensureLoaded();

    // 服务端全自动处理：搜索取首个候选并写入歌手/歌词/专辑/封面。
    final wants = _fields.map((f) => f.name).toList();
    final writeMode = _writeMode == MatchWriteMode.overwrite
        ? 'overwrite'
        : 'fill';
    final preferFilename = MatchSettings.preferFilename.value;
    final lyricOptions = <String, dynamic>{
      'convert': switch (MatchSettings.chineseConvert.value) {
        ChineseTextConvert.simplifiedToTraditional => 'simplifiedToTraditional',
        ChineseTextConvert.traditionalToSimplified => 'traditionalToSimplified',
        ChineseTextConvert.none => 'none',
      },
      'removeBlankLines': MatchSettings.removeBlankLines.value,
      'filterRules': MatchSettings.filterRules.value,
    };
    final songs = widget.songs
        .map(
          (s) => {
            'guid': s.id,
            'title': s.title,
            'artist': s.artistDisplayName,
            'album': s.albumDisplayName,
            'duration': s.durationMs ?? 0,
          },
        )
        .toList();

    try {
      final results = await BackendMatchClient.instance.batchMatch(
        songs: songs,
        sources: MatchSourceState.instance.enabledIdsInOrder,
        wants: wants,
        writeMode: writeMode,
        preferFilename: preferFilename,
        lyricOptions: lyricOptions,
      );
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _status[r.guid] = r.matched ? 'done' : 'error';
        }
        _success = results.where((r) => r.matched).length;
        _failed = results.length - _success;
        _running = false;
        _phase = 'done';
      });
      // 批量匹配可能写入歌词：失效本地歌词缓存，播放时从 API 读取最新
      for (final r in results) {
        if (r.lyricsUpdated) {
          await LyricsRepository().removeCachedLrc(r.guid);
        }
      }
      if (!mounted) return;
      AppToast.show(context, '批量匹配完成：成功 $_success，失败 $_failed');
    } catch (e) {
      debugPrint('[BatchMatch] 批量匹配失败: $e');
      if (!mounted) return;
      setState(() => _running = false);
      AppToast.show(context, '批量匹配失败：$e', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '批量匹配数据',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: _phase == 'confirm'
          ? _buildConfirmPage(context)
          : _buildProgressPage(context),
    );
  }

  // ── 确认页 ─────────────────────────────────────────────────────

  Widget _buildConfirmPage(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        AppSettingSection(
          title: '匹配范围',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '共 ${widget.songs.length} 首歌曲',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            // 选中歌曲封面横排缩略图
            if (widget.songs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.songs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final song = widget.songs[index];
                      return ArtworkWidget(
                        song: song,
                        size: 44,
                        borderRadius: 8,
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        AppSettingSection(
          title: '匹配字段',
          children: [
            // 全选 / 取消全选
            Row(
              children: [
                const SizedBox(width: 12),
                Text('全选', style: theme.textTheme.bodyMedium),
                const Spacer(),
                Checkbox(
                  value: _fields.length == MatchField.values.length,
                  tristate:
                      _fields.isNotEmpty &&
                      _fields.length != MatchField.values.length,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _fields.addAll(MatchField.values);
                      } else {
                        _fields.clear();
                      }
                    });
                  },
                ),
              ],
            ),
            const Divider(height: 1),
            for (final field in MatchField.values)
              AppSettingCheckboxTile(
                title: field.label,
                subtitle: _fieldDescription(field),
                value: _fields.contains(field),
                onChanged: (v) {
                  setState(() {
                    if (v) {
                      _fields.add(field);
                    } else {
                      _fields.remove(field);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        AppSettingSection(
          title: '写入模式',
          children: [
            RadioGroup<MatchWriteMode>(
              groupValue: _writeMode,
              onChanged: (v) {
                if (v != null) setState(() => _writeMode = v);
              },
              child: Column(
                children: [
                  for (final mode in MatchWriteMode.values)
                    RadioListTile<MatchWriteMode>(
                      title: Text(mode.label),
                      subtitle: Text(mode.description),
                      value: mode,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text('开始匹配 ${widget.songs.length} 首'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _fieldDescription(MatchField field) {
    switch (field) {
      case MatchField.title:
        return '匹配歌曲标题';
      case MatchField.artist:
        return '匹配歌手并关联到飞牛歌手';
      case MatchField.album:
        return '匹配所属专辑';
      case MatchField.year:
        return '匹配发行年份';
      case MatchField.trackNumber:
        return '匹配歌曲序号';
      case MatchField.discNumber:
        return '匹配光盘序号';
      case MatchField.cover:
        return '匹配封面并上传到 NAS';
      case MatchField.lyrics:
        return '匹配歌词（写入服务端增强）';
    }
  }

  // ── 执行页 ─────────────────────────────────────────────────────

  Widget _buildProgressPage(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card(
            margin: EdgeInsets.zero,
            color: theme.cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _running
                        ? '正在匹配 $_completed/${widget.songs.length}'
                        : '批量匹配完成',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: widget.songs.isEmpty
                        ? 1
                        : _completed / widget.songs.length,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _statChip(theme, '总数', widget.songs.length),
                      _statChip(theme, '成功', _success),
                      _statChip(theme, '失败', _failed),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: widget.songs.length,
            itemBuilder: (context, index) {
              final song = widget.songs[index];
              final status = _status[song.id] ?? 'pending';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ArtworkWidget(song: song, size: 44, borderRadius: 8),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  song.artistDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: switch (status) {
                  'running' => const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  'done' => Icon(
                    Icons.check_circle_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  'error' => Icon(
                    Icons.error_rounded,
                    color: theme.colorScheme.error,
                  ),
                  _ => Icon(
                    Icons.schedule_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                },
                // 批量匹配由服务端全自动处理，单首不可单独重匹配
                onTap: null,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _statChip(ThemeData theme, String label, int value) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Column(
        children: [
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: label == '失败' && value > 0
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

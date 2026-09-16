import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/audio/stream_cache_service.dart';
import '../../app/services/cover_local_cache.dart';
import '../../app/services/db/dao/song_dao.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

/// 封面缓存目录名 —— flutter_cache_manager 3.x 固定为 libCachedImageData
///
/// CachedNetworkImage / DefaultCacheManager 共用此目录，
/// 位于 getTemporaryDirectory()/libCachedImageData/。
const String kArtworkCacheDirName = 'libCachedImageData';

/// 通知封面兜底下载目录（media_notification_service 的 fallback）。
/// 通知封面正常路径也走 flutter_cache_manager（libCachedImageData），
/// 仅当自签名证书导致缓存管理器下载失败时才写入此目录，因此并入封面缓存统一管理。
const String kNotificationCoverDirName = 'notification_covers';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage>
    with SignalsMixin {
  late final _artworkCacheSize = createSignal(0);
  late final _lyricsCacheSize = createSignal(0);
  late final _apiCacheCount = createSignal(0);
  late final _streamCacheSize = createSignal(0);
  late final _loading = createSignal(true);

  @override
  void initState() {
    super.initState();
    AppCacheSettings.ensureLoaded();
    _loadCacheSizes();
  }

  Future<void> _loadCacheSizes() async {
    _loading.value = true;
    final artworkSize = await _getArtworkCacheSize();
    final lyricsSize = await _getLyricsCacheSize();
    final apiCount = await _getApiCacheCount();
    final streamSize = await StreamCacheService.instance.totalSize();
    if (!mounted) return;
    _artworkCacheSize.value = artworkSize;
    _lyricsCacheSize.value = lyricsSize;
    _apiCacheCount.value = apiCount;
    _streamCacheSize.value = streamSize;
    _loading.value = false;
  }

  /// 封面图缓存（flutter_cache_manager，目录 getTemporaryDirectory()/libCachedImageData/），
  /// 另含通知封面兜底目录 getTemporaryDirectory()/notification_covers/。
  Future<int> _getArtworkCacheSize() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(tempDir.path, kArtworkCacheDirName));
      final notifDir = Directory(
        p.join(tempDir.path, kNotificationCoverDirName),
      );
      final carCoverDir = Directory(
        p.join(tempDir.path, CoverLocalCache.kDirName),
      );
      return await _dirSize(cacheDir) +
          await _dirSize(notifDir) +
          await _dirSize(carCoverDir);
    } catch (_) {
      return 0;
    }
  }

  /// 歌词缓存（getApplicationSupportDirectory()/lyrics）
  Future<int> _getLyricsCacheSize() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return await _dirSize(Directory(p.join(dir.path, 'lyrics')));
    } catch (_) {
      return 0;
    }
  }

  /// DB 内 API 响应缓存条目数（api_cache 表）
  Future<int> _getApiCacheCount() async {
    try {
      return await SongDao.instance.apiCacheCount();
    } catch (_) {
      return 0;
    }
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final f in dir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          total += await f.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// 删除目录内容（保留目录本身，避免后续写缓存报错）
  Future<void> _clearDirContents(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        await entity.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _clearArtworkCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除封面缓存',
      content: '确定要清除封面缓存吗？这将需要重新下载封面。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(tempDir.path, kArtworkCacheDirName));
      await _clearDirContents(cacheDir);
      // 通知封面兜底目录并入封面缓存一并清理
      final notifDir = Directory(
        p.join(tempDir.path, kNotificationCoverDirName),
      );
      await _clearDirContents(notifDir);
      final carCoverDir = Directory(
        p.join(tempDir.path, CoverLocalCache.kDirName),
      );
      await _clearDirContents(carCoverDir);
    } catch (_) {}
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '封面缓存已清除');
  }

  Future<void> _clearLyricsCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除歌词缓存',
      content: '确定要清除歌词缓存吗？本地歌词会在需要时重新读取。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory(p.join(dir.path, 'lyrics'));
    try {
      await _clearDirContents(cacheDir);
    } catch (_) {}
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '歌词缓存已清除');
  }

  Future<void> _clearApiCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除数据缓存',
      content: '确定要清除已缓存的首页/列表数据吗？下次打开需要重新加载。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    try {
      await SongDao.instance.clearApiCache();
    } catch (_) {}
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '数据缓存已清除');
  }

  Future<void> _clearStreamCache() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '清除音乐缓存',
      content: '确定要清除已缓存的音乐吗？下次播放需要重新下载。',
    );
    if (confirmed != true) return;

    _loading.value = true;
    try {
      await StreamCacheService.instance.clearAll();
    } catch (_) {}
    if (!mounted) return;
    await _loadCacheSizes();
    if (!mounted) return;
    AppToast.show(context, '音乐缓存已清除');
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  String _formatGb(int mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

  String _formatCacheLimit(int mb) => mb == 0 ? '无限制' : _formatGb(mb);

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '缓存设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: Watch.builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
          children: [
            AppSettingSection(
              title: '缓存管理',
              children: [
                AppSettingTile(
                  title: '封面缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '占用空间: ${_formatSize(_artworkCacheSize.value)}',
                  trailing: const Icon(Icons.image_outlined),
                  onTap: _loading.value ? null : _clearArtworkCache,
                ),
                AppSettingTile(
                  title: '歌词缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '占用空间: ${_formatSize(_lyricsCacheSize.value)}',
                  trailing: const Icon(Icons.description_outlined),
                  onTap: _loading.value ? null : _clearLyricsCache,
                ),
                AppSettingTile(
                  title: '数据缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '缓存条目: ${_apiCacheCount.value} 条',
                  trailing: const Icon(Icons.data_usage_outlined),
                  onTap: _loading.value ? null : _clearApiCache,
                ),
                AppSettingTile(
                  title: '音乐缓存',
                  subtitle: _loading.value
                      ? '计算中...'
                      : '已缓存: ${_formatSize(_streamCacheSize.value)} / '
                            '上限 ${_formatCacheLimit(AppCacheSettings.cacheLimitMb.value)}',
                  trailing: const Icon(Icons.audiotrack_outlined),
                  onTap: _loading.value ? null : _clearStreamCache,
                ),
              ],
            ),
            AppSettingSection(
              title: '缓存设置',
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: AppCacheSettings.cacheLimitMb,
                  builder: (_, limitMb, _) => AppSettingSwitchTile(
                    title: '缓存空间无限制',
                    subtitle: '不自动清理已缓存的音乐',
                    value: limitMb == 0,
                    onChanged: AppCacheSettings.setUnlimited,
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: AppCacheSettings.cacheLimitMb,
                  builder: (_, limitMb, _) => limitMb == 0
                      ? const SizedBox.shrink()
                      : AppSettingSlider(
                          title: '缓存上限',
                          value: limitMb.toDouble(),
                          min: 256,
                          max: 5120,
                          divisions: 19,
                          valueText: _formatGb(limitMb),
                          description: '超出上限时自动清理最旧的缓存。',
                          onChanged: (v) =>
                              AppCacheSettings.setCacheLimitMb(v.round()),
                        ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: AppCacheSettings.precacheNextSong,
                  builder: (_, on, _) => AppSettingSwitchTile(
                    title: '预缓存下一首',
                    subtitle: '当前歌曲缓存完成后自动缓存下一首',
                    value: on,
                    onChanged: (v) => AppCacheSettings.setPrecacheNextSong(v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

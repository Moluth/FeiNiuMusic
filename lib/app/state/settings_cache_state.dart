import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存相关设置（音频流缓存）
///
/// 音频流缓存在播放时自动把流下载到本地，拖动进度条在已缓存区域内可秒播。
/// - [cacheLimitMb]：缓存空间上限（MB），0 表示无限制且为默认值；
///   正数超出后自动清理最旧的缓存。
///   旧版休眠设置 `audio_cache_limit_gb`（0-5，默认 0，无人消费）仅在迁移时读取。
/// - [precacheNextSong]：当前歌曲缓存完成后自动缓存下一首。
class AppCacheSettings {
  static const String _prefsCacheLimitMb = 'audio_cache_limit_mb';
  static const String _prefsLastLimitedCacheMb = 'audio_cache_last_limited_mb';
  static const String _prefsLegacyCacheLimitGb = 'audio_cache_limit_gb';
  static const String _prefsPrecacheNextSong = 'audio_precache_next_song';
  static const int defaultLimitedCacheMb = 1024;

  /// 缓存上限（MB）。0=无限制（默认），有限模式为 256–5120MB。
  static final ValueNotifier<int> cacheLimitMb = ValueNotifier(0);
  static int _lastLimitedCacheMb = defaultLimitedCacheMb;

  /// 当前歌曲缓存完成后自动缓存下一首
  static final ValueNotifier<bool> precacheNextSong = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();

    var mb = prefs.getInt(_prefsCacheLimitMb);
    if (mb == null) {
      // 旧版休眠设置迁移：非零 GB 按 1024 换算；没有有效旧设置时
      // 使用新的默认值“无限制”。
      final legacyGb = prefs.getInt(_prefsLegacyCacheLimitGb) ?? 0;
      mb = legacyGb > 0 ? legacyGb * 1024 : 0;
      if (legacyGb > 0) {
        await prefs.setInt(_prefsCacheLimitMb, mb);
        await prefs.remove(_prefsLegacyCacheLimitGb);
      }
    }
    cacheLimitMb.value = mb <= 0 ? 0 : mb.clamp(256, 5120);
    _lastLimitedCacheMb =
        prefs.getInt(_prefsLastLimitedCacheMb) ??
        (cacheLimitMb.value > 0 ? cacheLimitMb.value : defaultLimitedCacheMb);

    precacheNextSong.value = prefs.getBool(_prefsPrecacheNextSong) ?? true;
  }

  /// 设置缓存上限（MB）。超限淘汰由 StreamCacheService 监听 [cacheLimitMb] 处理。
  static Future<void> setCacheLimitMb(int mb) async {
    final value = mb <= 0 ? 0 : mb.clamp(256, 5120);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsCacheLimitMb, value);
    if (value > 0) {
      _lastLimitedCacheMb = value;
      await prefs.setInt(_prefsLastLimitedCacheMb, value);
    }
    cacheLimitMb.value = value;
  }

  static Future<void> setUnlimited(bool unlimited) {
    return setCacheLimitMb(unlimited ? 0 : _lastLimitedCacheMb);
  }

  static Future<void> setPrecacheNextSong(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsPrecacheNextSong, enabled);
    precacheNextSong.value = enabled;
  }

  /// 测试用：重置懒加载与内存状态，使 ensureLoaded 可重新读取
  @visibleForTesting
  static void resetForTest() {
    _loading = null;
    cacheLimitMb.value = 0;
    _lastLimitedCacheMb = defaultLimitedCacheMb;
    precacheNextSong.value = true;
  }
}

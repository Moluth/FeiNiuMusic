import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/audio/stream_cache_service.dart';
import 'package:feiniu_music/app/state/settings_cache_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';

SongEntity _song(String id, {String? format}) =>
    SongEntity(id: id, title: id, artist: '[{"name":"t"}]', format: format);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppCacheSettings.resetForTest();
    StreamCacheService.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> withTempDir(Future<void> Function(String base) body) async {
    final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final base = '${tmp.path}${Platform.pathSeparator}';
    await body(base);
  }

  group('AppCacheSettings', () {
    test('defaults: cacheLimitMb = 0 (unlimited)', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 0);
      expect(AppCacheSettings.precacheNextSong.value, true);
    });

    test(
      'setCacheLimitMb accepts unlimited and clamps finite limits',
      () async {
        SharedPreferences.setMockInitialValues({});
        await AppCacheSettings.ensureLoaded();

        await AppCacheSettings.setCacheLimitMb(0);
        expect(AppCacheSettings.cacheLimitMb.value, 0);

        await AppCacheSettings.setCacheLimitMb(9999);
        expect(AppCacheSettings.cacheLimitMb.value, 5120);

        await AppCacheSettings.setCacheLimitMb(10);
        expect(AppCacheSettings.cacheLimitMb.value, 256);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('audio_cache_limit_mb'), 256);
      },
    );

    test('persistence round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      await AppCacheSettings.setCacheLimitMb(2048);
      await AppCacheSettings.setPrecacheNextSong(false);

      // 重新加载应读到持久化值
      AppCacheSettings.resetForTest();
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 2048);
      expect(AppCacheSettings.precacheNextSong.value, false);
    });

    test(
      'legacy audio_cache_limit_gb=3 migrates to 3072 and removes key',
      () async {
        SharedPreferences.setMockInitialValues({'audio_cache_limit_gb': 3});
        await AppCacheSettings.ensureLoaded();
        expect(AppCacheSettings.cacheLimitMb.value, 3072);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('audio_cache_limit_mb'), 3072);
        expect(prefs.getInt('audio_cache_limit_gb'), isNull);
      },
    );

    test('legacy zero value migrates to unlimited', () async {
      SharedPreferences.setMockInitialValues({'audio_cache_limit_gb': 0});
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 0);
    });

    test('unlimited toggle restores the last finite limit', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      await AppCacheSettings.setCacheLimitMb(2048);

      await AppCacheSettings.setUnlimited(true);
      expect(AppCacheSettings.cacheLimitMb.value, 0);

      await AppCacheSettings.setUnlimited(false);
      expect(AppCacheSettings.cacheLimitMb.value, 2048);
    });

    test('precacheNextSong setter persists', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      await AppCacheSettings.setPrecacheNextSong(false);
      expect(AppCacheSettings.precacheNextSong.value, false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('audio_precache_next_song'), false);
    });
  });

  group('StreamCacheService pure logic', () {
    test('duplicate song IDs share one scheduled download', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var calls = 0;

      final first = StreamCacheService.instance.scheduleDownloadForTest(
        'same-song',
        () async {
          calls++;
          started.complete();
          await release.future;
        },
      );
      await started.future;
      final duplicate = StreamCacheService.instance.scheduleDownloadForTest(
        'same-song',
        () async => calls++,
      );

      await duplicate;
      expect(calls, 1);
      release.complete();
      await first;
    });

    test('safeCacheName sanitizes and keeps valid chars', () {
      expect(StreamCacheService.safeCacheName('abc-123._x'), 'abc-123._x');
      expect(StreamCacheService.safeCacheName('a/b:c*d'), 'a_b_c_d');
      expect(StreamCacheService.safeCacheName(''), 'song');
    });

    test('completeFileFor returns existing file and null otherwise', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 1024; // 开启缓存

      final missing = await StreamCacheService.instance.completeFileFor(
        's1',
        song: _song('s1'),
      );
      expect(missing, isNull);

      final file = File(
        '${tmp.path}${Platform.pathSeparator}${StreamCacheService.safeCacheName('s1')}.mp3',
      );
      await file.writeAsBytes([1, 2, 3]);

      final found = await StreamCacheService.instance.completeFileFor(
        's1',
        song: _song('s1'),
      );
      expect(found, isNotNull);
      expect(found!.path, file.path);
    });

    test('cache file extension follows song format (flac → .flac)', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 1024;

      // format 已知：无需出网，直接落 .flac
      final flacFile = await StreamCacheService.instance.completeFileFor(
        's1',
        song: _song('s1', format: 'flac'),
      );
      expect(flacFile, isNull);

      final flac = File(
        '${tmp.path}${Platform.pathSeparator}${StreamCacheService.safeCacheName('s1')}.flac',
      );
      await flac.writeAsBytes([1, 2, 3]);
      final found = await StreamCacheService.instance.completeFileFor(
        's1',
        song: _song('s1', format: 'flac'),
      );
      expect(found, isNotNull);
      expect(found!.path, flac.path);

      // 历史 `.mp3` 后缀缓存兼容命中
      final legacyMp3 = File(
        '${tmp.path}${Platform.pathSeparator}${StreamCacheService.safeCacheName('s2')}.mp3',
      );
      await legacyMp3.writeAsBytes([1]);
      final viaLegacy = await StreamCacheService.instance.completeFileFor(
        's2',
        song: _song('s2', format: 'flac'),
      );
      expect(viaLegacy, isNotNull);
      expect(viaLegacy!.path, legacyMp3.path);
    });

    test(
      'unknown format finds existing cache without metadata lookup',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
        addTearDown(() => tmp.delete(recursive: true));
        await StreamCacheService.instance.setDirectoryForTest(tmp);
        AppCacheSettings.cacheLimitMb.value = 1024;

        final cached = File(
          '${tmp.path}${Platform.pathSeparator}'
          '${StreamCacheService.safeCacheName('unknown')}.flac',
        );
        await cached.writeAsBytes([1, 2, 3]);

        final found = await StreamCacheService.instance.completeFileFor(
          'unknown',
          song: _song('unknown'),
          allowMetadataLookup: false,
        );

        expect(found?.path, cached.path);
      },
    );

    test('extensionForSongSync uses format when present', () {
      expect(
        StreamCacheService.instance.extensionForSongSync(
          _song('a', format: 'FLAC'),
        ),
        'flac',
      );
      expect(
        StreamCacheService.instance.extensionForSongSync(
          _song('b', format: 'mp3'),
        ),
        'mp3',
      );
      expect(
        StreamCacheService.instance.extensionForSongSync(
          _song('c', format: 'dsf'),
        ),
        'dsf',
      );
      // 未知格式 → null（走运行时 MIME/默认兜底）
      expect(
        StreamCacheService.instance.extensionForSongSync(
          _song('d', format: 'lossless'),
        ),
        isNull,
      );
    });

    test(
      'evictIfNeeded deletes oldest complete files, protects active',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
        addTearDown(() => tmp.delete(recursive: true));
        await StreamCacheService.instance.setDirectoryForTest(tmp);
        AppCacheSettings.cacheLimitMb.value = 1; // 1MB 上限

        // 4 首完整缓存，各 ~400KB，总计 ~1.6MB > 1MB
        final base = tmp.path + Platform.pathSeparator;
        // mtime 顺序：old 最旧（60×3 分钟前）→ mid → new → current 最新（60×0）
        final ids = ['old', 'mid', 'new', 'current'];
        final now = DateTime.now();
        for (var i = 0; i < ids.length; i++) {
          final f = File(
            '$base${StreamCacheService.safeCacheName(ids[i])}.mp3',
          );
          await f.writeAsBytes(List.filled(400 * 1024, i + 1));
          await f.setLastModified(
            now.subtract(Duration(minutes: 60 * (3 - i))),
          );
        }

        // .part / .mime 依附于具体歌曲；被淘汰歌曲的 .mime 随之删除，
        // 但进行中的 .part 永不参与淘汰删除（此处挂在未淘汰的 'new' 上）
        final part = File(
          '$base${StreamCacheService.safeCacheName('new')}.mp3.part',
        );
        final mime = File(
          '$base${StreamCacheService.safeCacheName('new')}.mp3.mime',
        );
        await part.writeAsBytes([9]);
        await mime.writeAsString('audio/mpeg');

        // 保护 current（当前播放）与 new（活跃注册表）
        StreamCacheService.instance.currentSongId = 'current';
        await StreamCacheService.instance.evictIfNeeded(
          protectedSongIds: {'new'},
        );

        // 淘汰按 mtime 最旧优先：old → mid → new → current，直到总量 ≤ 1MB。
        // 初始 1.6MB；删 old(400K) → 1.2MB 仍超；删 mid(400K) → 800KB ≤ 1MB 停。
        expect(
          File(
            '$base${StreamCacheService.safeCacheName('old')}.mp3',
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            '$base${StreamCacheService.safeCacheName('mid')}.mp3',
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            '$base${StreamCacheService.safeCacheName('new')}.mp3',
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            '$base${StreamCacheService.safeCacheName('current')}.mp3',
          ).existsSync(),
          isTrue,
        );
        expect(part.existsSync(), isTrue, reason: '进行中的 .part 不应被删除');
        expect(mime.existsSync(), isTrue, reason: '未淘汰歌曲的 .mime 不应被删除');

        // 保护列表按 mtime 排序 → current 最新；即使保护失效也应最后删。验证保护生效：
        // 若未保护 new/current，则 new 在 current 之前（new 较旧）被删。
        expect(
          File(
            '$base${StreamCacheService.safeCacheName('new')}.mp3',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test('unlimited cache skips eviction', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 0;

      final file = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('keep')}.mp3',
      );
      await file.writeAsBytes(List.filled(1024, 1));

      await StreamCacheService.instance.evictIfNeeded();

      expect(file.existsSync(), isTrue);
    });

    test('transient cache expires only after ten days', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      final now = DateTime.utc(2026, 9, 14, 12);
      final expired = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('expired')}.mp3',
      );
      final boundary = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('boundary')}.mp3',
      );
      await expired.writeAsBytes([1]);
      await boundary.writeAsBytes([1]);
      await StreamCacheService.instance.markTransientUsed(
        'expired',
        usedAt: now.subtract(const Duration(days: 10, seconds: 1)),
      );
      await StreamCacheService.instance.markTransientUsed(
        'boundary',
        usedAt: now.subtract(const Duration(days: 10)),
      );

      await StreamCacheService.instance.cleanupExpiredTransientCache(now: now);

      expect(expired.existsSync(), isFalse);
      expect(boundary.existsSync(), isTrue);
    });

    test(
      'untracked legacy cache expires from file modification time',
      () async {
        final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
        addTearDown(() => tmp.delete(recursive: true));
        await StreamCacheService.instance.setDirectoryForTest(tmp);
        final now = DateTime.utc(2026, 9, 14, 12);
        final legacy = File(
          '${tmp.path}${Platform.pathSeparator}'
          '${StreamCacheService.safeCacheName('legacy')}.mp3',
        );
        await legacy.writeAsBytes([1]);
        await legacy.setLastModified(
          now.subtract(const Duration(days: 10, seconds: 1)),
        );

        await StreamCacheService.instance.cleanupExpiredTransientCache(
          now: now,
        );

        expect(legacy.existsSync(), isFalse);
      },
    );

    test('owner replacement starts retention when a song is removed', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      final removed = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('removed')}.mp3',
      );
      await removed.writeAsBytes([1]);
      await StreamCacheService.instance.setLongTermOwnerSongs('owner', [
        'removed',
      ], replace: true);
      await StreamCacheService.instance.setLongTermOwnerSongs(
        'owner',
        const <String>[],
        replace: true,
      );

      await StreamCacheService.instance.cleanupExpiredTransientCache(
        now: DateTime.now().add(const Duration(days: 9)),
      );

      expect(removed.existsSync(), isTrue);
    });

    test('favorite and playlist owners protect long-term cache', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      final now = DateTime.utc(2026, 9, 14, 12);
      final favorite = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('favorite')}.flac',
      );
      final playlist = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('playlist')}.mp3',
      );
      await favorite.writeAsBytes([1]);
      await playlist.writeAsBytes([1]);
      final old = now.subtract(const Duration(days: 30));
      await StreamCacheService.instance.markTransientSongs([
        'favorite',
        'playlist',
      ], usedAt: old);
      await StreamCacheService.instance.setLongTermOwnerSongs(
        StreamCacheService.favoriteRetentionOwner,
        ['favorite'],
      );
      await StreamCacheService.instance.setLongTermOwnerSongs(
        StreamCacheService.playlistRetentionOwner('playlist-a'),
        ['playlist'],
      );

      await StreamCacheService.instance.cleanupExpiredTransientCache(now: now);

      expect(favorite.existsSync(), isTrue);
      expect(playlist.existsSync(), isTrue);
    });

    test('account-scoped owners do not collide', () {
      expect(
        StreamCacheService.favoriteRetentionOwnerFor('account-a'),
        isNot(StreamCacheService.favoriteRetentionOwnerFor('account-b')),
      );
      expect(
        StreamCacheService.playlistRetentionOwner(
          'playlist-a',
          accountId: 'account-a',
        ),
        isNot(
          StreamCacheService.playlistRetentionOwner(
            'playlist-a',
            accountId: 'account-b',
          ),
        ),
      );
    });

    test('playlist owner protects transcoded cache during eviction', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 1;
      final protected = File(
        '${tmp.path}${Platform.pathSeparator}'
        'tc_${StreamCacheService.safeCacheName('favorite')}_flac.mp4',
      );
      final disposable = File(
        '${tmp.path}${Platform.pathSeparator}'
        '${StreamCacheService.safeCacheName('disposable')}.mp3',
      );
      await protected.writeAsBytes(List<int>.filled(700 * 1024, 1));
      await disposable.writeAsBytes(List<int>.filled(700 * 1024, 2));
      await StreamCacheService.instance.setLongTermOwnerSongs(
        StreamCacheService.playlistRetentionOwner('playlist-a'),
        ['favorite'],
      );

      await StreamCacheService.instance.evictIfNeeded();

      expect(protected.existsSync(), isTrue);
      expect(disposable.existsSync(), isFalse);
    });
  });

  group('旧缓存目录一次性清理', () {
    test('首次调用删除旧目录并写标记', () async {
      await withTempDir((base) async {
        // 模拟旧版 app-support 目录中的缓存文件
        final legacy = Directory('$base${StreamCacheService.legacyDirName}');
        await legacy.create(recursive: true);
        final file = File('${legacy.path}${Platform.pathSeparator}song.mp3');
        await file.writeAsBytes([1, 2, 3]);
        expect(legacy.existsSync(), isTrue);

        await StreamCacheService.instance.cleanupLegacyDirOnce(
          legacyDir: legacy,
        );

        expect(legacy.existsSync(), isFalse, reason: '旧缓存目录应被删除');
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getBool('stream_cache_legacy_cleanup_done'),
          isTrue,
          reason: '清理完成后应写入去重标记',
        );
      });
    });

    test('标记已写则不再删除目录', () async {
      await withTempDir((base) async {
        // 预置标记，模拟上一次启动已完成清理
        SharedPreferences.setMockInitialValues({
          'stream_cache_legacy_cleanup_done': true,
        });
        final legacy = Directory('$base${StreamCacheService.legacyDirName}');
        await legacy.create(recursive: true);
        final file = File('${legacy.path}${Platform.pathSeparator}song.mp3');
        await file.writeAsBytes([1, 2, 3]);

        await StreamCacheService.instance.cleanupLegacyDirOnce(
          legacyDir: legacy,
        );

        expect(legacy.existsSync(), isTrue, reason: '标记已写，不应再次删除');
        expect(
          File('${legacy.path}${Platform.pathSeparator}song.mp3').existsSync(),
          isTrue,
        );
      });
    });

    test('旧目录不存在时仍写标记（幂等）', () async {
      await withTempDir((base) async {
        final absent = Directory('$base${StreamCacheService.legacyDirName}');

        await StreamCacheService.instance.cleanupLegacyDirOnce(
          legacyDir: absent,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('stream_cache_legacy_cleanup_done'), isTrue);
        expect(absent.existsSync(), isFalse);
      });
    });
  });
}

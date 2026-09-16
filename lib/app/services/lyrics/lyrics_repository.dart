import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../state/song_state.dart';
import '../feiniu/api_client.dart';

class LyricsRepository {
  static const Duration refreshInterval = Duration(days: 5);
  static final Map<String, Future<void>> _refreshes = <String, Future<void>>{};
  static final Map<String, int> _writeVersions = <String, int>{};
  static final Map<String, Future<void>> _writes = <String, Future<void>>{};

  /// 加载歌词，优先从缓存读取，未命中则从 API 获取
  Future<String?> loadLrc(SongEntity song) async {
    // 1. 读取本地缓存
    final file = await _cacheFileForSongId(song.id);
    final cached = await _readFromFile(file);
    if (cached != null && cached.trim().isNotEmpty) {
      if (!await _isFresh(file)) {
        _refreshInBackground(song);
      }
      return cached;
    }

    // 2. 从 API 获取
    return _fetchAndCache(song, expectedVersion: _writeVersions[song.id] ?? 0);
  }

  Future<String?> _fetchAndCache(
    SongEntity song, {
    required int expectedVersion,
  }) async {
    try {
      final lyricText = await FeiNiuApiClient.instance.getLyricText(song.id);
      if (lyricText != null && lyricText.trim().isNotEmpty) {
        if ((_writeVersions[song.id] ?? 0) != expectedVersion) return null;
        await _writeToCache(
          song.id,
          lyricText,
          expectedVersion: expectedVersion,
        );
        if ((_writeVersions[song.id] ?? 0) != expectedVersion) return null;
        return lyricText;
      }
    } catch (_) {
      // API 返回失败时静默处理
    }

    return null;
  }

  void _refreshInBackground(SongEntity song) {
    if (_refreshes.containsKey(song.id)) return;
    final version = _writeVersions[song.id] ?? 0;
    final future = _fetchAndCache(
      song,
      expectedVersion: version,
    ).then<void>((_) {});
    _refreshes[song.id] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_refreshes[song.id], future)) {
          _refreshes.remove(song.id);
        }
      }),
    );
  }

  Future<bool> _isFresh(File file) async {
    try {
      return isCacheFresh(
        modifiedAt: (await file.stat()).modified,
        now: DateTime.now(),
      );
    } catch (_) {
      return false;
    }
  }

  static bool isCacheFresh({
    required DateTime modifiedAt,
    required DateTime now,
  }) {
    final age = now.difference(modifiedAt);
    return !age.isNegative && age < refreshInterval;
  }

  Future<void> removeCachedLrc(String songId) async {
    _writeVersions[songId] = (_writeVersions[songId] ?? 0) + 1;
    await _enqueueSongWrite(songId, () async {
      try {
        final file = await _cacheFileForSongId(songId);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    });
  }

  Future<void> saveLrcToCache(
    String songId,
    String content, {
    bool overwrite = false,
  }) async {
    final c = content.replaceFirst('﻿', '').trim();
    if (c.isEmpty) return;
    _writeVersions[songId] = (_writeVersions[songId] ?? 0) + 1;
    if (!overwrite) {
      final exists = await hasCachedLrc(songId);
      if (exists) return;
    }
    await _writeToCache(songId, c);
  }

  Future<bool> hasCachedLrc(String songId) async {
    try {
      final file = await _cacheFileForSongId(songId);
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> loadCachedLrc(String songId) async {
    return _readFromCache(songId);
  }

  Future<String?> _readFromCache(String songId) async {
    try {
      final file = await _cacheFileForSongId(songId);
      return await _readFromFile(file);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readFromFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToCache(
    String songId,
    String content, {
    int? expectedVersion,
  }) {
    return _enqueueSongWrite(songId, () async {
      if (expectedVersion != null &&
          (_writeVersions[songId] ?? 0) != expectedVersion) {
        return;
      }
      try {
        final dir = await getApplicationSupportDirectory();
        final lyricsDir = Directory(p.join(dir.path, 'lyrics'));
        if (!await lyricsDir.exists()) {
          await lyricsDir.create(recursive: true);
        }
        if (expectedVersion != null &&
            (_writeVersions[songId] ?? 0) != expectedVersion) {
          return;
        }
        final file = File(p.join(lyricsDir.path, '${_cacheKey(songId)}.lrc'));
        await file.writeAsString(content, flush: true);
      } catch (_) {}
    });
  }

  Future<void> _enqueueSongWrite(
    String songId,
    Future<void> Function() operation,
  ) {
    final previous = _writes[songId] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) => operation());
    _writes[songId] = next;
    return next.whenComplete(() {
      if (identical(_writes[songId], next)) {
        _writes.remove(songId);
      }
    });
  }

  Future<File> _cacheFileForSongId(String songId) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'lyrics', '${_cacheKey(songId)}.lrc'));
  }

  String _cacheKey(String songId) {
    final bytes = utf8.encode(songId);
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask64 = 0xFFFFFFFFFFFFFFFF;
    var hash = offsetBasis;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * prime) & mask64;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}

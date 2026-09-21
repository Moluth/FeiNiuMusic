import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/settings_cache_state.dart';
import '../state/song_state.dart';
import 'audio/stream_cache_service.dart';
import 'cover_local_cache.dart';
import 'feiniu/account_store.dart';
import 'feiniu/api_client.dart';
import 'feiniu/track_service.dart';
import 'lyrics/lyrics_repository.dart';
import 'player_service.dart';

/// 在播放器空闲时为收藏歌曲准备离线音频、封面和歌词。
class FavoriteMediaCacheService {
  FavoriteMediaCacheService._();

  static final FavoriteMediaCacheService instance =
      FavoriteMediaCacheService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final LyricsRepository _lyrics = LyricsRepository();
  final Set<String> _queuedIds = <String>{};

  Future<void>? _allFavoritesTask;
  Future<void> _playlistTaskChain = Future<void>.value();
  String? _activeAccountId;
  Timer? _scheduleTimer;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    AccountStore.instance.currentAccountId.addListener(_onAccountChanged);
    _scheduleForCurrentAccount(const Duration(seconds: 20));
  }

  void _onAccountChanged() {
    _scheduleForCurrentAccount(const Duration(seconds: 2));
  }

  void _scheduleForCurrentAccount(Duration delay) {
    _scheduleTimer?.cancel();
    final accountId = AccountStore.instance.currentAccountId.value;
    if (accountId == null || accountId.isEmpty) return;
    _scheduleTimer = Timer(delay, () {
      unawaited(cacheAllFavorites());
    });
  }

  Future<void> cacheAllFavorites() {
    final accountId = AccountStore.instance.currentAccountId.value;
    if (accountId == null || accountId.isEmpty) return Future<void>.value();
    final active = _allFavoritesTask;
    if (active != null) {
      if (_activeAccountId == accountId) return active;
      return active.whenComplete(() {
        if (AccountStore.instance.currentAccountId.value == accountId) {
          return cacheAllFavorites();
        }
      });
    }
    _activeAccountId = accountId;
    return _allFavoritesTask = _cacheAllFavorites(accountId).whenComplete(() {
      _allFavoritesTask = null;
      _activeAccountId = null;
    });
  }

  Future<void> cacheFavoriteById(String songId) async {
    if (!_queuedIds.add(songId)) return;
    try {
      await AppCacheSettings.ensureLoaded();
      if (!StreamCacheService.instance.isEnabled) return;
      final accountId = AccountStore.instance.currentAccountId.value;
      if (accountId == null || accountId.isEmpty) return;
      final baseUrl = _api.baseUrl;
      final token = _api.token;
      final track = await _api.getTrackMetadata(songId);
      if (track == null) return;
      await _waitForPlaybackIdle();
      if (AccountStore.instance.currentAccountId.value != accountId ||
          _api.baseUrl != baseUrl ||
          _api.token != token) {
        return;
      }
      await _cacheSong(_trackService.trackToSongEntity(track.toJson()));
    } catch (error) {
      debugPrint('[FavoriteCache] cache $songId failed: $error');
    } finally {
      _queuedIds.remove(songId);
    }
  }

  /// 在播放器空闲时为已加载的歌单歌曲准备长期音频、封面和歌词缓存。
  Future<void> cachePlaylistSongs(Iterable<SongEntity> songs) {
    final pendingSongs = songs.toList(growable: false);
    if (pendingSongs.isEmpty) return Future<void>.value();
    final accountId = AccountStore.instance.currentAccountId.value;
    final baseUrl = _api.baseUrl;
    final token = _api.token;
    final next = _playlistTaskChain.catchError((_) {}).then((_) async {
      if (accountId == null ||
          accountId.isEmpty ||
          AccountStore.instance.currentAccountId.value != accountId ||
          _api.baseUrl != baseUrl ||
          _api.token != token) {
        return;
      }
      for (final song in pendingSongs) {
        await _waitForPlaybackIdle();
        if (AccountStore.instance.currentAccountId.value != accountId ||
            _api.baseUrl != baseUrl ||
            _api.token != token) {
          return;
        }
        if (!_queuedIds.add(song.id)) continue;
        try {
          await _cacheSong(song);
        } catch (error) {
          debugPrint('[PlaylistCache] cache ${song.id} failed: $error');
        } finally {
          _queuedIds.remove(song.id);
        }
      }
    });
    _playlistTaskChain = next.catchError((_) {});
    return next;
  }

  Future<void> _cacheAllFavorites(String accountId) async {
    try {
      await AppCacheSettings.ensureLoaded();
      if (!StreamCacheService.instance.isEnabled) return;

      final baseUrl = _api.baseUrl;
      final token = _api.token;
      if (baseUrl.isEmpty || token.isEmpty) return;
      await _waitForPlaybackIdle();
      if (AccountStore.instance.currentAccountId.value != accountId ||
          _api.baseUrl != baseUrl ||
          _api.token != token) {
        return;
      }
      // 与飞牛网页端保持一致，一次读取全部收藏。部分服务端版本在分页请求
      // 中会把 total 返回为当前页大小，导致 100 首之后永远不会继续拉取。
      final response = await _api.getFavoriteList(page: 1, size: -1);
      final favoriteIds = response.list.map((track) => track.guid).toSet();
      await StreamCacheService.instance.setLongTermOwnerSongs(
        StreamCacheService.favoriteRetentionOwnerFor(accountId),
        favoriteIds,
        replace: true,
      );

      for (final track in response.list) {
        await _waitForPlaybackIdle();
        if (AccountStore.instance.currentAccountId.value != accountId ||
            _api.baseUrl != baseUrl ||
            _api.token != token) {
          return;
        }
        final song = _trackService.trackToSongEntity(track.toJson());
        if (_queuedIds.add(song.id)) {
          try {
            await _cacheSong(song);
          } finally {
            _queuedIds.remove(song.id);
          }
        }
      }
    } catch (error) {
      debugPrint('[FavoriteCache] cache favorites failed: $error');
    }
  }

  Future<void> _cacheSong(SongEntity song) async {
    await Future.wait<void>([
      StreamCacheService.instance.cacheSongAndWait(song),
      if (song.coverId != null && song.coverId!.isNotEmpty)
        CoverLocalCache.downloadToLocal(
          song.coverId!,
          updatedAt: song.updatedAt,
          size: FeiNiuApiClient.coverRequestSize,
          persistent: true,
        ).then<void>((_) {}),
      _lyrics.loadLrc(song).then<void>((_) {}),
    ]);
  }

  Future<void> _waitForPlaybackIdle() async {
    final player = PlayerService.instance;
    while (player.isPlaying.value || player.isLoading.value) {
      await Future<void>.delayed(const Duration(seconds: 15));
    }
  }
}

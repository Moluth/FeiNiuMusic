import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/stream_cache_service.dart';
import '../favorite_media_cache_service.dart';
import 'account_store.dart';
import 'api_client.dart';

/// 飞牛收藏服务
class FeiNiuFavoriteService {
  FeiNiuFavoriteService._();

  static final FeiNiuFavoriteService instance = FeiNiuFavoriteService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final ValueNotifier<Map<String, bool>> favoriteStates =
      ValueNotifier<Map<String, bool>>(const <String, bool>{});
  final ValueNotifier<Set<String>> pendingIds = ValueNotifier<Set<String>>(
    const <String>{},
  );
  final Map<String, int> _revisions = <String, int>{};
  final Map<String, Future<bool>> _refreshes = <String, Future<bool>>{};

  String get _favoriteOwner => StreamCacheService.favoriteRetentionOwnerFor(
    AccountStore.instance.currentAccountId.value,
  );

  void _runCacheUpdate(Future<void> update) {
    unawaited(
      update.catchError((Object error) {
        if (kDebugMode) {
          debugPrint('[FavoriteService] cache owner update failed: $error');
        }
      }),
    );
  }

  bool favoriteState(String trackGuid, {bool fallback = false}) {
    return favoriteStates.value[trackGuid] ?? fallback;
  }

  void seedFavoriteState(String trackGuid, bool isFavorite) {
    if (favoriteStates.value.containsKey(trackGuid)) return;
    _publishFavoriteState(trackGuid, isFavorite);
  }

  Future<bool> refreshFavoriteState(String trackGuid) {
    final existing = _refreshes[trackGuid];
    if (existing != null) return existing;
    final revision = _revisions[trackGuid] ?? 0;
    final future = _refreshFavoriteState(trackGuid, revision);
    _refreshes[trackGuid] = future;
    future.whenComplete(() {
      if (identical(_refreshes[trackGuid], future)) {
        _refreshes.remove(trackGuid);
      }
    });
    return future;
  }

  Future<bool> _refreshFavoriteState(String trackGuid, int revision) async {
    try {
      final refreshedValue = await isFavorite(trackGuid);
      if ((_revisions[trackGuid] ?? 0) == revision) {
        _publishFavoriteState(trackGuid, refreshedValue);
      }
    } catch (_) {
      // 保留本地已知状态；网络恢复后下一次刷新会重新校准。
    }
    return favoriteState(trackGuid);
  }

  /// 获取收藏歌曲 ID 集合
  Future<Set<String>> getFavoriteIds() async {
    final pageData = await _api.getFavoriteList();
    return pageData.list.map((t) => t.guid).toSet();
  }

  /// 获取收藏歌曲列表
  Future<List<dynamic>> getFavoriteList() async {
    final pageData = await _api.getFavoriteList();
    return pageData.list;
  }

  /// 收藏歌曲
  Future<void> favorite(String trackGuid) async {
    await setFavorite(trackGuid, true);
  }

  /// 批量收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> favoriteAll(List<String> trackGuids) async {
    var failed = 0;
    final favoriteOwner = _favoriteOwner;
    for (final id in trackGuids) {
      try {
        await _api.favoriteTrack(id);
        _publishFavoriteState(id, true);
        _runCacheUpdate(
          StreamCacheService.instance.setLongTermOwnerSongs(favoriteOwner, [
            id,
          ]),
        );
        unawaited(FavoriteMediaCacheService.instance.cacheFavoriteById(id));
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 取消收藏
  Future<void> unfavorite(String trackGuid) async {
    await setFavorite(trackGuid, false);
  }

  /// 批量取消收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> unfavoriteAll(List<String> trackGuids) async {
    var failed = 0;
    final favoriteOwner = _favoriteOwner;
    for (final id in trackGuids) {
      try {
        await _api.unfavoriteTrack(id);
        _publishFavoriteState(id, false);
        _runCacheUpdate(
          StreamCacheService.instance.removeLongTermOwnerSongs(favoriteOwner, [
            id,
          ]),
        );
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 检查是否已收藏
  Future<bool> isFavorite(String trackGuid) async {
    final ids = await getFavoriteIds();
    return ids.contains(trackGuid);
  }

  /// 乐观更新收藏状态：先通知 UI/媒体会话，再同步服务端；失败时回滚。
  Future<void> setFavorite(String trackGuid, bool value) async {
    if (pendingIds.value.contains(trackGuid)) return;
    final favoriteOwner = _favoriteOwner;
    final previous = favoriteStates.value[trackGuid] ?? !value;
    _revisions[trackGuid] = (_revisions[trackGuid] ?? 0) + 1;
    _publishFavoriteState(trackGuid, value);
    _setPending(trackGuid, true);
    try {
      if (value) {
        await _api.favoriteTrack(trackGuid);
        _runCacheUpdate(
          StreamCacheService.instance.setLongTermOwnerSongs(favoriteOwner, [
            trackGuid,
          ]),
        );
        unawaited(
          FavoriteMediaCacheService.instance.cacheFavoriteById(trackGuid),
        );
      } else {
        await _api.unfavoriteTrack(trackGuid);
        _runCacheUpdate(
          StreamCacheService.instance.removeLongTermOwnerSongs(favoriteOwner, [
            trackGuid,
          ]),
        );
      }
    } catch (_) {
      _publishFavoriteState(trackGuid, previous);
      rethrow;
    } finally {
      _setPending(trackGuid, false);
    }
  }

  void _publishFavoriteState(String trackGuid, bool value) {
    if (favoriteStates.value[trackGuid] == value) return;
    favoriteStates.value = Map<String, bool>.unmodifiable(<String, bool>{
      ...favoriteStates.value,
      trackGuid: value,
    });
  }

  void _setPending(String trackGuid, bool pending) {
    final next = Set<String>.of(pendingIds.value);
    if (pending) {
      next.add(trackGuid);
    } else {
      next.remove(trackGuid);
    }
    pendingIds.value = Set<String>.unmodifiable(next);
  }

  @visibleForTesting
  void resetForTest() {
    favoriteStates.value = const <String, bool>{};
    pendingIds.value = const <String>{};
    _revisions.clear();
    _refreshes.clear();
  }
}

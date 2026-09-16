import 'package:flutter/foundation.dart';

import '../audio/stream_cache_service.dart';
import 'account_store.dart';
import 'api_client.dart';
import 'api_models.dart';

/// 飞牛歌单服务（所有操作通过 API）
class FeiNiuPlaylistService {
  FeiNiuPlaylistService._();

  static final FeiNiuPlaylistService instance = FeiNiuPlaylistService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  Future<void> _syncOwner(Future<void> update) async {
    try {
      await update;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PlaylistService] cache owner update failed: $error');
      }
    }
  }

  /// 获取歌单列表（分页）。
  ///
  /// 默认 `size: -1`（一次返回全部），供歌单选择器等需要完整列表的场景使用；
  /// 歌单页传入 `page`/`size` 做滚动加载更多。
  Future<List<FeiNiuPlaylist>> getPlaylistList({
    int page = 1,
    int size = -1,
  }) async {
    final pageData = await _api.getPlaylistList(page: page, size: size);
    return pageData.list;
  }

  /// 获取歌单内歌曲
  Future<List<FeiNiuTrack>> getPlaylistTracks(
    String playlistGuid, {
    int page = 1,
    int size = 300,
  }) async {
    final pageData = await getPlaylistTrackPage(
      playlistGuid,
      page: page,
      size: size,
    );
    return pageData.list;
  }

  Future<FeiNiuPageData<FeiNiuTrack>> getPlaylistTrackPage(
    String playlistGuid, {
    int page = 1,
    int size = 300,
  }) async {
    final owner = _playlistOwner(playlistGuid);
    final pageData = await _api.getPlaylistTracks(
      playlistGUID: playlistGuid,
      page: page,
      size: size,
    );
    await _syncOwner(
      StreamCacheService.instance.setLongTermOwnerSongs(
        owner,
        pageData.list.map((track) => track.guid),
        replace:
            page == 1 && (size < 0 || pageData.list.length >= pageData.total),
      ),
    );
    return pageData;
  }

  Future<void> syncPlaylistOwner(
    String playlistGuid,
    Iterable<String> trackGuids, {
    bool replace = false,
  }) {
    return _syncOwner(
      StreamCacheService.instance.setLongTermOwnerSongs(
        _playlistOwner(playlistGuid),
        trackGuids,
        replace: replace,
      ),
    );
  }

  String _playlistOwner(String playlistGuid) =>
      StreamCacheService.playlistRetentionOwner(
        playlistGuid,
        accountId: AccountStore.instance.currentAccountId.value,
      );

  /// 创建歌单。
  ///
  /// 未传 [coverId] 时上传随机封面；传入用户自选封面的 coverId 时直接使用。
  Future<FeiNiuPlaylist> createPlaylist(String name, {String? coverId}) async {
    // 没有自定义封面时上传随机封面
    final finalCoverId = coverId ?? await _api.uploadCover();
    final playlist = await _api.createPlaylist(name, coverId: finalCoverId);
    return playlist;
  }

  /// 上传本地图片作为歌单封面，返回 coverId。失败时抛异常。
  Future<String> uploadCoverFromFile(String imagePath) async {
    return _api.uploadCoverFromFile(imagePath);
  }

  /// 删除歌单
  Future<void> deletePlaylist(String guid) async {
    final owner = _playlistOwner(guid);
    await _api.deletePlaylist(guid);
    await _syncOwner(StreamCacheService.instance.removeLongTermOwner(owner));
  }

  /// 清除歌单内无效歌曲，返回清除数量
  Future<int> purgeInvalidTracks(String playlistGuid) async {
    final removed = await _api.purgeInvalidTracks(playlistGuid);
    if (removed > 0) {
      await getPlaylistTracks(playlistGuid, size: -1);
    }
    return removed;
  }

  /// 编辑歌单（名称/封面）
  Future<void> editPlaylist({
    required String guid,
    String? name,
    String? coverId,
  }) async {
    await _api.editPlaylist(guid: guid, name: name, coverId: coverId);
  }

  /// 添加歌曲到歌单
  Future<void> addTrack(String playlistGuid, String trackGuid) async {
    final owner = _playlistOwner(playlistGuid);
    await _api.addTrackToPlaylist(playlistGuid, [trackGuid]);
    await _syncOwner(
      StreamCacheService.instance.setLongTermOwnerSongs(owner, [trackGuid]),
    );
  }

  /// 添加多首歌曲到歌单
  Future<void> addTracks(String playlistGuid, List<String> trackGuids) async {
    final owner = _playlistOwner(playlistGuid);
    await _api.addTrackToPlaylist(playlistGuid, trackGuids);
    await _syncOwner(
      StreamCacheService.instance.setLongTermOwnerSongs(owner, trackGuids),
    );
  }

  /// 从歌单移除歌曲
  Future<void> removeTrack(String playlistGuid, String trackGuid) async {
    final owner = _playlistOwner(playlistGuid);
    await _api.removeTrackFromPlaylist(playlistGuid, trackGuid);
    await _syncOwner(
      StreamCacheService.instance.removeLongTermOwnerSongs(owner, [trackGuid]),
    );
  }

  /// 从歌单批量移除歌曲（一次请求提交全部）
  Future<void> removeTracks(
    String playlistGuid,
    List<String> trackGuids,
  ) async {
    final owner = _playlistOwner(playlistGuid);
    await _api.removeTracksFromPlaylist(playlistGuid, trackGuids);
    await _syncOwner(
      StreamCacheService.instance.removeLongTermOwnerSongs(owner, trackGuids),
    );
  }
}

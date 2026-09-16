import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../state/settings_match.dart';
import '../../state/song_state.dart';
import '../../utils/map_concurrent.dart';
import '../companion/metadata_companion_service.dart';
import '../feiniu/api_client.dart';
import '../feiniu/api_models.dart';
import 'backend_match_client.dart';
import 'match_source_state.dart';
import 'song_match_models.dart';

/// 可匹配的字段（用户可在批量匹配确认页选择应用哪些）。
enum MatchField {
  title,
  artist,
  album,
  year,
  trackNumber,
  discNumber,
  cover,
  lyrics,
}

extension MatchFieldLabel on MatchField {
  String get label => switch (this) {
    MatchField.title => '标题',
    MatchField.artist => '歌手',
    MatchField.album => '专辑',
    MatchField.year => '年份',
    MatchField.trackNumber => '歌曲序号',
    MatchField.discNumber => '光盘序号',
    MatchField.cover => '封面',
    MatchField.lyrics => '歌词',
  };
}

/// 匹配写入模式：覆盖（用匹配结果覆盖现有值）或填充（仅当现有值为空时写入）。
enum MatchWriteMode { overwrite, fill }

extension MatchWriteModeLabel on MatchWriteMode {
  String get label => this == MatchWriteMode.overwrite ? '覆盖' : '填充（仅空值）';

  String get description => this == MatchWriteMode.overwrite
      ? '用匹配到的结果覆盖当前歌曲的对应字段'
      : '仅当当前字段为空时才写入匹配结果';
}

/// 批量匹配选项（用户在确认页选择）。
class MatchOptions {
  final Set<MatchField> fields;
  final MatchWriteMode writeMode;
  final bool autoConfirmCandidates; // true=取第一个候选；false=逐首弹候选确认

  const MatchOptions({
    this.fields = const {MatchField.title, MatchField.artist, MatchField.album},
    this.writeMode = MatchWriteMode.fill,
    this.autoConfirmCandidates = true,
  });
}

class FilenameMetadataResetResult {
  final List<SongEntity> updatedSongs;
  final int failedCount;

  const FilenameMetadataResetResult({
    required this.updatedSongs,
    required this.failedCount,
  });
}

/// 单曲匹配结果（应用到一个 SongEntity 的字段）。
class SongMatchPatch {
  final String title;
  final String artist; // 匹配到的歌手名（多歌手用分隔符）
  final String album;
  final String year;
  final String trackNumber;
  final String discNumber;
  final String? coverBytes; // base64 或 null；由上层转为上传
  final String? coverUrl;

  /// 匹配到的歌词（LRC 文本）；未获取时为 null。
  final String? lyrics;

  const SongMatchPatch({
    required this.title,
    required this.artist,
    required this.album,
    this.year = '',
    this.trackNumber = '',
    this.discNumber = '',
    this.coverBytes,
    this.coverUrl,
    this.lyrics,
  });
  bool get hasCover => coverBytes != null || (coverUrl?.isNotEmpty ?? false);
}

/// 歌曲匹配服务：把后端搜索候选转换为可应用到歌曲的补丁。
class SongMatchService {
  SongMatchService._internal();

  static final SongMatchService instance = SongMatchService._internal();

  final BackendMatchClient _backend = BackendMatchClient.instance;
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final Map<String, ({DateTime createdAt, GroupedSongResults results})>
  _searchCache = {};
  final Map<String, Future<GroupedSongResults>> _searchInflight = {};
  static const _searchCacheTtl = Duration(minutes: 2);
  static const _entityCacheTtl = Duration(minutes: 5);
  String? _entityCacheScope;
  DateTime? _artistCacheCreatedAt;
  DateTime? _albumCacheCreatedAt;
  List<FeiNiuArtist>? _artistCache;
  List<FeiNiuAlbum>? _albumCache;
  Future<List<FeiNiuArtist>>? _artistInflight;
  Future<List<FeiNiuAlbum>>? _albumInflight;

  /// 将曲目标题替换为无扩展名文件名，并清空歌手、专辑和年份后写回 NAS。
  ///
  /// 保留封面、流派、曲序和碟号；单首失败不会中断其余曲目。
  Future<FilenameMetadataResetResult> resetMetadataToFilenames(
    List<SongEntity> songs, {
    int concurrency = 3,
  }) async {
    final attempts = await mapConcurrent(songs, concurrency, (song) async {
      try {
        final track = await _api.getTrackMetadata(song.id);
        if (track == null) {
          throw StateError('无法读取曲目元数据');
        }
        final body = filenameMetadataResetBody(track);
        await _api.updateTrackMetadata(body);
        return song.copyWith(
          title: body['title'] as String,
          artist: '[]',
          album: jsonEncode(const <String, String>{'name': ''}),
        );
      } catch (e) {
        debugPrint('[SongMatch] 文件名替换歌名失败 ${song.id}: $e');
        return null;
      }
    });
    final updatedSongs = attempts.whereType<SongEntity>().toList();
    return FilenameMetadataResetResult(
      updatedSongs: updatedSongs,
      failedCount: songs.length - updatedSongs.length,
    );
  }

  static Map<String, dynamic> filenameMetadataResetBody(FeiNiuTrack track) {
    final title = filenameFromPath(track.audioSpec?.path);
    if (title.isEmpty) {
      throw StateError('曲目文件名为空');
    }
    final coverId = track.coverId;
    return <String, dynamic>{
      'guid': track.guid,
      'title': title,
      'album': '',
      'artistGUIDs': const <String>[],
      'genreGUIDs': track.genres.map((genre) => genre.guid).toList(),
      'year': null,
      'trackNo': track.trackNo,
      'discNo': track.discNo,
      if (coverId != null && coverId.isNotEmpty) 'coverId': coverId,
      if (coverId != null && coverId.isNotEmpty)
        'coverGUID': FeiNiuApiClient.deriveCoverGuid(coverId),
    };
  }

  /// 当前是否可用（已配置服务端增强地址 + 已登录）。
  bool get available => _backend.available;

  /// 搜索匹配候选（后端多平台搜索），**按客户端启用的平台顺序**分组返回。
  Future<GroupedSongResults> searchCandidates(
    String keyword, {
    int page = 1,
    int pageSize = 20,
  }) {
    final sources = MatchSourceState.instance.enabledIdsInOrder;
    final key = [
      _api.baseUrl,
      _api.token.hashCode,
      keyword.trim(),
      sources.join(','),
      page,
      pageSize,
    ].join('|');
    final now = DateTime.now();
    final cached = _searchCache[key];
    if (cached != null && now.difference(cached.createdAt) < _searchCacheTtl) {
      return Future<GroupedSongResults>.value(cached.results);
    }
    final existing = _searchInflight[key];
    if (existing != null) return existing;
    final future = _backend.searchSongs(
      keyword: keyword,
      sources: sources,
      page: page,
      pageSize: pageSize,
    );
    _searchInflight[key] = future;
    future
        .then((results) {
          _searchCache[key] = (createdAt: DateTime.now(), results: results);
          if (_searchCache.length > 24) {
            final oldest = _searchCache.entries.reduce(
              (a, b) => a.value.createdAt.isBefore(b.value.createdAt) ? a : b,
            );
            _searchCache.remove(oldest.key);
          }
        }, onError: (_) {})
        .whenComplete(() {
          if (identical(_searchInflight[key], future)) {
            _searchInflight.remove(key);
          }
        });
    return future;
  }

  /// 搜索封面候选（后端多平台搜索）。
  ///
  /// [searchType] 规范取值：0=歌曲，1=歌手，2=专辑（后端按各平台类型映射）。
  Future<List<SongMatchResult>> searchCovers(
    String keyword, {
    int page = 1,
    int pageSize = 10,
    int searchType = 0,
  }) {
    return _backend.searchCovers(
      keyword: keyword,
      sources: MatchSourceState.instance.enabledIdsInOrder,
      page: page,
      pageSize: pageSize,
      searchType: searchType,
    );
  }

  /// 构造搜索关键词。
  ///
  /// [preferFilename] 开关开启时（[MatchSettings.preferFilename]），优先用
  /// 音频文件名（去扩展名）作为关键词，忽略内置标题/歌手标签；否则用
  /// 标题 + 歌手。
  ///
  /// 文件名模式匹配时自动过滤开头序号（如 `01. 歌名`、`01 - 歌名`、
  /// `01-歌名`、`[01] 歌名`）。
  ///
  /// [filePath] 为音频文件路径（`FeiNiuAudioSpec.path`），用于提取文件名。
  String buildKeyword({
    required String title,
    required String artist,
    String? filePath,
    bool? preferFilename,
  }) {
    final useFilename = preferFilename ?? MatchSettings.preferFilename.value;
    if (useFilename && filePath != null && filePath.isNotEmpty) {
      var name = p.basenameWithoutExtension(filePath).trim();
      // 过滤开头序号：数字 + 分隔符（`.`/`-`/`_`/空格/`]`）前缀
      name = name.replaceFirst(
        RegExp(r'^(?:\d{1,3}|\[?\d{1,3}\]?)[\s.\-_·]*(?=[^\s\d.])'),
        '',
      );
      name = name.trim();
      if (name.isNotEmpty) return name;
    }
    return [title, artist].where((s) => s.isNotEmpty).join(' ').trim();
  }

  /// 从文件路径提取文件名（去扩展名）；无效返回空。
  static String filenameFromPath(String? filePath) {
    if (filePath == null || filePath.isEmpty) return '';
    return p.basenameWithoutExtension(filePath).trim();
  }

  /// 把选中的候选应用为补丁（标题/歌手/专辑/年份 + 可选封面下载）。
  ///
  /// [downloadCover] 为 true 时下载候选 picUrl 到内存（失败则补丁不带封面）。
  Future<SongMatchPatch> buildPatch(
    SongMatchResult candidate, {
    bool downloadCover = false,
  }) async {
    String? coverBytes;
    if (downloadCover && candidate.picUrl.isNotEmpty) {
      coverBytes = await _downloadCoverToBase64(candidate.picUrl);
    }
    return SongMatchPatch(
      title: candidate.title,
      artist: candidate.artist,
      album: candidate.album,
      year: candidate.date,
      trackNumber: candidate.trackNumber,
      discNumber: candidate.discNumber,
      coverBytes: coverBytes,
      coverUrl: candidate.picUrl,
    );
  }

  /// 从后端获取歌词（LRC），按歌词模式 + 翻译/罗马音偏好渲染。
  ///
  /// [pluginId] 指定候选来自的平台（只查该平台）；否则按客户端启用平台顺序
  /// 遍历，取第一个有歌词的。返回 null 表示未获取到歌词。
  Future<String?> fetchLyrics({
    required String title,
    required String artist,
    String album = '',
    int duration = 0,
    String? sourceId, // 源平台歌曲 id（来自 searchSongs 候选），供定位歌词
    Map<String, String>? sourceInternal,
    Map<String, String>? sourceFields,
    String? pluginId, // 候选来自哪个平台（只查该平台歌词）
  }) async {
    final platforms = pluginId != null
        ? [pluginId]
        : MatchSourceState.instance.enabledIdsInOrder;
    // 客户端偏好：简繁转换 / 移除空行 / 过滤规则（传服务端处理）
    final convert = switch (MatchSettings.chineseConvert.value) {
      ChineseTextConvert.simplifiedToTraditional => 'simplifiedToTraditional',
      ChineseTextConvert.traditionalToSimplified => 'traditionalToSimplified',
      ChineseTextConvert.none => 'none',
    };
    final removeBlankLines = MatchSettings.removeBlankLines.value;
    final filterRules = MatchSettings.filterRules.value;
    for (final platform in platforms) {
      final result = await _backend.fetchLyrics(
        platform: platform,
        songId: sourceId ?? title,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        convert: convert,
        removeBlankLines: removeBlankLines,
        filterRules: filterRules,
      );
      if (result == null) continue;
      // 优先后端 structured（词级/行级）；无则从 rawPlainLrc 降级解析行级。
      final original = result.original.isNotEmpty
          ? result.original
          : linesFromPlainLrc(result.rawPlainLrc);
      if (original.isEmpty) continue;
      final candidate = LyricMatchResult(
        pluginId: 'backend',
        pluginName: '后端',
        type: 'structured',
        tags: {'ti': title, 'ar': artist, 'al': album},
        original: original,
        translated: result.translated,
        romanization: result.romanization,
      );
      final mode = MatchSettings.lyricMode.value;
      final includeTranslation = MatchSettings.translation.value;
      final includeRomanization = MatchSettings.romanization.value;
      final onlyTranslation = MatchSettings.onlyTranslation.value;
      final text = candidate.lyricsFor(
        mode,
        includeTranslation: includeTranslation,
        includeRomanization: includeRomanization,
        onlyTranslation: onlyTranslation,
      );
      if (text.trim().isNotEmpty) return text;
    }
    return null;
  }

  /// 把匹配到的歌手名解析为飞牛 FeiNiuArtist（用于 artistGUIDs）。
  ///
  /// 按名字精确匹配；**匹配不到时自动调用 `/artist/create` 新建歌手**
  /// （避免匹配结果因歌手不存在而丢失）。新建失败时跳过该名字。
  /// [separator] 支持多歌手分隔符拆分。
  Future<List<FeiNiuArtist>> resolveArtists(
    String artistNames, {
    String separator = '/',
  }) async {
    if (artistNames.trim().isEmpty) return [];
    final artists = await _getArtistsCached();

    final names = artistNames
        .split(RegExp(RegExp.escape(separator)))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final byName = <String, FeiNiuArtist>{};
    for (final artist in artists) {
      byName[artist.name] = artist;
    }

    final resolved = <FeiNiuArtist>[];
    for (final name in names) {
      final match = byName[name];
      if (match != null && !resolved.contains(match)) {
        resolved.add(match);
        continue;
      }
      if (match == null) {
        // 库中不存在 → 自动创建，保证匹配的歌手名能正确关联
        try {
          final created = await _api.createArtist(name);
          byName[created.name] = created;
          _artistCache = [...?_artistCache, created];
          if (!resolved.contains(created)) resolved.add(created);
        } catch (e) {
          debugPrint('创建歌手 "$name" 失败: $e');
        }
      }
    }
    return resolved;
  }

  /// 把匹配到的专辑名解析为飞牛 FeiNiuAlbum（用于回填专辑 guid）。
  ///
  /// 按名字精确匹配；**匹配不到且服务端增强可用时自动创建专辑**（主 API 无
  /// `album/create`，走服务端增强 `createEntity`），避免服务端按字符串隐式新建出
  /// 重复专辑。服务端增强不可用（中继 / 未登录）或创建失败返回 null
  /// （调用方回退原专辑字符串）。
  Future<FeiNiuAlbum?> resolveAlbum(String albumName) async {
    final name = albumName.trim();
    if (name.isEmpty) return null;

    // 先在库中精确匹配
    final albums = await _getAlbumsCached();
    for (final album in albums) {
      if (album.name == name) return album;
    }

    // 库中不存在 → 服务端增强创建（已配置地址 + 已登录时尝试；失败回退 null）
    if (!MetadataCompanionService.instance.available) return null;
    try {
      final guid = await MetadataCompanionService.instance.createEntity(
        kind: EntityEditKind.album,
        name: name,
      );
      final created = FeiNiuAlbum(guid: guid, name: name);
      _albumCache = [...?_albumCache, created];
      return created;
    } catch (e) {
      debugPrint('创建专辑 "$name" 失败: $e');
      return null;
    }
  }

  void _ensureEntityCacheScope() {
    final scope = '${_api.baseUrl}|${_api.token.hashCode}';
    if (_entityCacheScope == scope) return;
    _entityCacheScope = scope;
    _artistCacheCreatedAt = null;
    _albumCacheCreatedAt = null;
    _artistCache = null;
    _albumCache = null;
    _artistInflight = null;
    _albumInflight = null;
  }

  Future<List<FeiNiuArtist>> _getArtistsCached() {
    _ensureEntityCacheScope();
    final now = DateTime.now();
    final cached = _artistCache;
    if (cached != null &&
        _artistCacheCreatedAt != null &&
        now.difference(_artistCacheCreatedAt!) < _entityCacheTtl) {
      return Future<List<FeiNiuArtist>>.value(cached);
    }
    final existing = _artistInflight;
    if (existing != null) return existing;
    final future = _api.getArtistListAll();
    _artistInflight = future;
    future
        .then((artists) {
          _artistCache = artists;
          _artistCacheCreatedAt = DateTime.now();
        }, onError: (_) {})
        .whenComplete(() {
          if (identical(_artistInflight, future)) _artistInflight = null;
        });
    return future;
  }

  Future<List<FeiNiuAlbum>> _getAlbumsCached() {
    _ensureEntityCacheScope();
    final now = DateTime.now();
    final cached = _albumCache;
    if (cached != null &&
        _albumCacheCreatedAt != null &&
        now.difference(_albumCacheCreatedAt!) < _entityCacheTtl) {
      return Future<List<FeiNiuAlbum>>.value(cached);
    }
    final existing = _albumInflight;
    if (existing != null) return existing;
    final future = _api.getAlbumListAll();
    _albumInflight = future;
    future
        .then((albums) {
          _albumCache = albums;
          _albumCacheCreatedAt = DateTime.now();
        }, onError: (_) {})
        .whenComplete(() {
          if (identical(_albumInflight, future)) _albumInflight = null;
        });
    return future;
  }

  /// 下载候选封面为 base64（供 [FeiNiuApiClient.uploadTrackCover] 上传 NAS）。
  ///
  /// 超时 15s；失败返回 null。
  Future<String?> _downloadCoverToBase64(String url) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.bytes,
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final response = await dio.get<Uint8List>(url);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      return _base64Encode(bytes);
    } catch (e) {
      return null;
    }
  }

  String _base64Encode(List<int> bytes) {
    // 手动 base64 编码（避免额外依赖 base64 包）
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final buffer = StringBuffer();
    var i = 0;
    while (i + 2 < bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write(chars[(n >> 6) & 63])
        ..write(chars[n & 63]);
      i += 3;
    }
    if (i + 1 == bytes.length) {
      final n = bytes[i] << 16;
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write('==');
    } else if (i + 2 == bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write(chars[(n >> 6) & 63])
        ..write('=');
    }
    return buffer.toString();
  }
}

/// 把行级 LRC 文本解析为 structured 行列表（无逐字时间戳）。
///
/// 解析 `[mm:ss.xx]text`（毫秒位支持 1~3 位）；纯时间戳行 / 空行忽略。
/// 供后端歌词（原文/翻译/罗马音三条 LRC）构造 [LyricMatchResult] 后走
/// `lyricsFor` 渲染。
List<LyricLine> linesFromPlainLrc(String lrc) {
  if (lrc.isEmpty) return const [];
  final lines = <LyricLine>[];
  final re = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?](.*)');
  for (final raw in lrc.split('\n')) {
    final m = re.firstMatch(raw.trim());
    if (m == null) continue;
    final minutes = int.tryParse(m.group(1)!);
    final seconds = int.tryParse(m.group(2)!);
    if (minutes == null || seconds == null) continue;
    var startMs = (minutes * 60 + seconds) * 1000;
    final fracRaw = m.group(3);
    if (fracRaw != null && fracRaw.isNotEmpty) {
      final frac = int.tryParse(fracRaw) ?? 0;
      final scale = fracRaw.length == 1
          ? 100
          : fracRaw.length == 2
          ? 10
          : 1;
      startMs += frac * scale;
    }
    final text = m.group(4)!.trim();
    if (text.isEmpty) continue;
    lines.add(LyricLine(startMs: startMs, endMs: startMs, text: text));
  }
  return lines;
}

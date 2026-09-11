import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_models.dart';
import 'package:feiniu_music/app/services/song_match/song_match_service.dart';

void main() {
  group('SongMatchService.buildKeyword', () {
    final service = SongMatchService.instance;

    test('默认用标题+歌手', () {
      final kw = service.buildKeyword(
        title: '晴天',
        artist: '周杰伦',
        preferFilename: false,
      );
      expect(kw, '晴天 周杰伦');
    });

    test('优先使用文件名：从路径提取 basename 去扩展名', () {
      final kw = service.buildKeyword(
        title: '错误标题',
        artist: '错误歌手',
        filePath: '/music/周杰伦 - 晴天.flac',
        preferFilename: true,
      );
      expect(kw, '周杰伦 - 晴天');
    });

    test('文件名匹配但路径无效：回退标题+歌手', () {
      final kw = service.buildKeyword(
        title: '晴天',
        artist: '周杰伦',
        filePath: '',
        preferFilename: true,
      );
      expect(kw, '晴天 周杰伦');
    });

    test('文件名匹配：保留文件名中的艺术家-标题分隔', () {
      final kw = service.buildKeyword(
        title: '',
        artist: '',
        filePath: 'E:/Music/林俊杰 可惜没如果.mp3',
        preferFilename: true,
      );
      expect(kw, '林俊杰 可惜没如果');
    });

    test('文件名匹配：自动过滤开头序号（01. / 01 - / [01] 前缀）', () {
      expect(
        service.buildKeyword(
          title: '',
          artist: '',
          filePath: 'E:/Music/01. 晴天.flac',
          preferFilename: true,
        ),
        '晴天',
      );
      expect(
        service.buildKeyword(
          title: '',
          artist: '',
          filePath: 'E:/Music/12 - 倒带.mp3',
          preferFilename: true,
        ),
        '倒带',
      );
      expect(
        service.buildKeyword(
          title: '',
          artist: '',
          filePath: 'E:/Music/[05] 海阔天空.flac',
          preferFilename: true,
        ),
        '海阔天空',
      );
    });

    test('文件名匹配：纯数字名不误删（无后续标题时保留）', () {
      final kw = service.buildKeyword(
        title: '',
        artist: '',
        filePath: 'E:/Music/123.flac',
        preferFilename: true,
      );
      expect(kw, '123', reason: '纯数字文件名不应被过滤成空');
    });
  });

  group('SongMatchService.filenameFromPath', () {
    test('提取 basename 去扩展名', () {
      expect(SongMatchService.filenameFromPath('/a/b/歌曲名.flac'), '歌曲名');
    });

    test('无路径返回空', () {
      expect(SongMatchService.filenameFromPath(null), '');
      expect(SongMatchService.filenameFromPath(''), '');
    });
  });

  group('SongMatchService.filenameMetadataResetBody', () {
    test('使用无后缀文件名并清空歌手专辑年份', () {
      final body = SongMatchService.filenameMetadataResetBody(
        const FeiNiuTrack(
          guid: 'track-1',
          title: '旧标题',
          year: 2020,
          trackNo: 3,
          discNo: 2,
          coverId: 'track_cover-1',
          createdAt: 1,
          updatedAt: 2,
          album: FeiNiuAlbum(guid: 'album-1', name: '旧专辑'),
          artists: [FeiNiuArtist(guid: 'artist-1', name: '旧歌手')],
          genres: [
            FeiNiuGenre(
              guid: 'genre-1',
              name: '流行',
              createdAt: 1,
              updatedAt: 2,
            ),
          ],
          audioSpec: FeiNiuAudioSpec(path: '/music/01. 新歌名.flac'),
        ),
      );

      expect(body['guid'], 'track-1');
      expect(body['title'], '01. 新歌名');
      expect(body['artistGUIDs'], isEmpty);
      expect(body['album'], '');
      expect(body['year'], isNull);
      expect(body['trackNo'], 3);
      expect(body['discNo'], 2);
      expect(body['genreGUIDs'], ['genre-1']);
      expect(body['coverId'], 'track_cover-1');
    });

    test('文件路径为空时拒绝清空元数据', () {
      expect(
        () => SongMatchService.filenameMetadataResetBody(
          const FeiNiuTrack(
            guid: 'track-1',
            title: '旧标题',
            createdAt: 1,
            updatedAt: 2,
            album: FeiNiuAlbum(guid: 'album-1', name: '旧专辑'),
            artists: [],
          ),
        ),
        throwsStateError,
      );
    });
  });
}

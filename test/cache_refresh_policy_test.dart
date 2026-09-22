import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/lyrics/lyrics_repository.dart';
import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/home/favorite_page.dart';

void main() {
  group('favorite count label', () {
    test('shows server total instead of the loaded page size', () {
      expect(
        favoriteCountText(loaded: 100, total: 268, hasMore: true),
        '已加载 100 / 共 268 首',
      );
      expect(
        favoriteCountText(loaded: 100, total: 0, hasMore: true),
        '已加载 100 首',
      );
      expect(
        favoriteCountText(loaded: 86, total: 86, hasMore: false),
        '共 86 首',
      );
      expect(
        favoriteCountText(loaded: 268, total: 100, hasMore: false),
        '共 268 首',
      );
    });
  });

  group('current song reselection', () {
    test('is ignored while playing or loading', () {
      expect(
        PlayerService.shouldOpenCurrentSongOnly(
          currentSongId: 'song-a',
          selectedSongId: 'song-a',
          isPlaying: true,
          isLoading: false,
        ),
        isTrue,
      );
      expect(
        PlayerService.shouldOpenCurrentSongOnly(
          currentSongId: 'song-a',
          selectedSongId: 'song-a',
          isPlaying: false,
          isLoading: true,
        ),
        isTrue,
      );
    });

    test('allows a paused song or a different song to play', () {
      expect(
        PlayerService.shouldOpenCurrentSongOnly(
          currentSongId: 'song-a',
          selectedSongId: 'song-a',
          isPlaying: false,
          isLoading: false,
        ),
        isFalse,
      );
      expect(
        PlayerService.shouldOpenCurrentSongOnly(
          currentSongId: 'song-a',
          selectedSongId: 'song-b',
          isPlaying: true,
          isLoading: false,
        ),
        isFalse,
      );
    });
  });

  group('lyrics cache freshness', () {
    test('is fresh before five days and stale at the boundary', () {
      final now = DateTime(2026, 9, 14, 12);

      expect(
        LyricsRepository.isCacheFresh(
          modifiedAt: now.subtract(const Duration(days: 4, hours: 23)),
          now: now,
        ),
        isTrue,
      );
      expect(
        LyricsRepository.isCacheFresh(
          modifiedAt: now.subtract(const Duration(days: 5)),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('roam queue prefill', () {
    test('keeps eight songs ahead when queue capacity allows', () {
      expect(
        PlayerService.shouldPrefillRoamQueue(
          queueLength: 8,
          currentIndex: 0,
          queueCap: 100,
        ),
        isTrue,
      );
      expect(
        PlayerService.shouldPrefillRoamQueue(
          queueLength: 9,
          currentIndex: 0,
          queueCap: 100,
        ),
        isFalse,
      );
    });

    test('respects small queue capacity', () {
      expect(
        PlayerService.shouldPrefillRoamQueue(
          queueLength: 3,
          currentIndex: 0,
          queueCap: 3,
        ),
        isFalse,
      );
      expect(
        PlayerService.shouldPrefillRoamQueue(
          queueLength: 3,
          currentIndex: 2,
          queueCap: 3,
        ),
        isFalse,
      );
    });
  });

  group('local shuffle queue', () {
    const songs = [
      SongEntity(id: 'a', title: 'A', artist: '[]'),
      SongEntity(id: 'b', title: 'B', artist: '[]'),
      SongEntity(id: 'c', title: 'C', artist: '[]'),
      SongEntity(id: 'd', title: 'D', artist: '[]'),
      SongEntity(id: 'e', title: 'E', artist: '[]'),
    ];

    test('keeps playback history and only shuffles upcoming songs', () {
      final shuffled = PlayerService.shuffleQueueAfterCurrent(
        songs,
        1,
        random: Random(7),
      );

      expect(shuffled.take(2).map((song) => song.id), ['a', 'b']);
      expect(shuffled.skip(2).map((song) => song.id).toSet(), {'c', 'd', 'e'});
      expect(songs.map((song) => song.id), ['a', 'b', 'c', 'd', 'e']);
    });

    test('keeps a queue at its final song unchanged', () {
      final shuffled = PlayerService.shuffleQueueAfterCurrent(
        songs,
        songs.length - 1,
        random: Random(7),
      );

      expect(shuffled.map((song) => song.id), ['a', 'b', 'c', 'd', 'e']);
      expect(identical(shuffled, songs), isFalse);
    });
  });
}

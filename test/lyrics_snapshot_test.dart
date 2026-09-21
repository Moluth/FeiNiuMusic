import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/widgets/lyric_view.dart' as fl;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/lyrics/lyrics_service.dart';
import 'package:feiniu_music/pages/player/lyrics/lyric_view.dart';

void main() {
  test('stale successful search reloads only the same current song', () {
    expect(
      shouldReloadStaleLyricsSearch(
        requestSequence: 1,
        currentSequence: 2,
        searchedLyrics: '[00:00.00]歌词',
        songId: 'song-1',
        currentSongId: 'song-1',
      ),
      isTrue,
    );
    expect(
      shouldReloadStaleLyricsSearch(
        requestSequence: 1,
        currentSequence: 2,
        searchedLyrics: '[00:00.00]歌词',
        songId: 'song-1',
        currentSongId: 'song-2',
      ),
      isFalse,
    );
    expect(
      shouldReloadStaleLyricsSearch(
        requestSequence: 2,
        currentSequence: 2,
        searchedLyrics: '[00:00.00]歌词',
        songId: 'song-1',
        currentSongId: 'song-1',
      ),
      isFalse,
    );
  });

  test('loading snapshot explicitly clears the previous lyric model', () {
    final model = LyricModel(
      lines: [LyricLine(start: Duration.zero, text: '旧歌词')],
    );
    final loaded = LyricsSnapshot(
      status: LyricsLoadStatus.loaded,
      song: null,
      model: model,
      error: null,
    );

    final loading = loaded.copyWith(
      status: LyricsLoadStatus.loading,
      clearModel: true,
    );

    expect(loading.status, LyricsLoadStatus.loading);
    expect(loading.model, isNull);
  });

  testWidgets('visible lyric view refreshes when downloaded lyrics arrive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final lyrics = LyricsService.instance;
    lyrics.controller.lyricNotifier.value = null;
    lyrics.snapshot.value = LyricsSnapshot.idle().copyWith(
      status: LyricsLoadStatus.empty,
      clearModel: true,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 600, child: PlayerLyricsView()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(fl.LyricView), findsNothing);

    final model = LyricModel(
      lines: [LyricLine(start: Duration.zero, text: '下载后的歌词')],
    );
    lyrics.controller.loadLyricModel(model);
    lyrics.snapshot.value = LyricsSnapshot(
      status: LyricsLoadStatus.loaded,
      song: null,
      model: model,
      error: null,
    );
    await tester.pump();

    expect(find.byType(fl.LyricView), findsOneWidget);
  });
}

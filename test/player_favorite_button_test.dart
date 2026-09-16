import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/favorite_service.dart';
import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_player_style_state.dart';
import 'package:feiniu_music/app/state/settings_playback_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/player/player_favorite_button.dart';
import 'package:feiniu_music/pages/player/widgets/player_bottom_panel.dart';

void main() {
  testWidgets('classic bottom favorite follows automatic song change', (
    tester,
  ) async {
    final player = PlayerService.instance;
    final favorites = FeiNiuFavoriteService.instance;
    final originalSong = player.currentSongSignal.value;
    final originalOrder = PlayerBottomActionSettings.actionOrder.value;
    addTearDown(() {
      player.currentSongSignal.value = originalSong;
      PlayerBottomActionSettings.actionOrder.value = originalOrder;
      favorites.resetForTest();
    });

    const favoriteSong = SongEntity(
      id: 'favorite-song',
      title: 'Favorite',
      artist: '[]',
      isFavorite: true,
    );
    const nextSong = SongEntity(
      id: 'next-song',
      title: 'Next',
      artist: '[]',
      isFavorite: false,
    );
    favorites.resetForTest();
    favorites.seedFavoriteState(favoriteSong.id, true);
    favorites.seedFavoriteState(nextSong.id, false);
    PlayerBottomActionSettings.actionOrder.value = const ['sleep_timer'];
    player.currentSongSignal.value = favoriteSong;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomActions(
            player: player,
            stylePreset: PlayerStylePreset.classic,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(
      tester
          .widget<PlayerFavoriteButton>(find.byType(PlayerFavoriteButton))
          .song
          ?.id,
      favoriteSong.id,
    );

    player.currentSongSignal.value = nextSong;
    await tester.pump();

    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(
      tester
          .widget<PlayerFavoriteButton>(find.byType(PlayerFavoriteButton))
          .song
          ?.id,
      nextSong.id,
    );

    // 组件会异步校准服务端收藏状态；推进 fake clock 让 Dio 超时计时器收尾。
    await tester.pump(const Duration(minutes: 11));
  });
}

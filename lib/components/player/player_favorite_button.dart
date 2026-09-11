import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/services/feiniu/favorite_service.dart';
import '../../app/state/song_state.dart';
import '../feedback/app_toast.dart';

class PlayerFavoriteButton extends StatefulWidget {
  final SongEntity? song;
  final double iconSize;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry padding;
  final VisualDensity? visualDensity;

  const PlayerFavoriteButton({
    super.key,
    required this.song,
    this.iconSize = 24,
    this.constraints,
    this.padding = const EdgeInsets.all(8),
    this.visualDensity,
  });

  @override
  State<PlayerFavoriteButton> createState() => _PlayerFavoriteButtonState();
}

class _PlayerFavoriteButtonState extends State<PlayerFavoriteButton> {
  final FeiNiuFavoriteService _favoriteService = FeiNiuFavoriteService.instance;

  @override
  void initState() {
    super.initState();
    _syncSong();
  }

  @override
  void didUpdateWidget(covariant PlayerFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.id != widget.song?.id) {
      _syncSong();
    }
  }

  void _syncSong() {
    final song = widget.song;
    if (song == null) return;
    _favoriteService.seedFavoriteState(song.id, song.isFavorite);
    unawaited(_favoriteService.refreshFavoriteState(song.id));
  }

  Future<void> _toggleFavorite() async {
    final song = widget.song;
    if (song == null) return;
    final wasFavorite = _favoriteService.favoriteState(
      song.id,
      fallback: song.isFavorite,
    );
    try {
      await _favoriteService.setFavorite(song.id, !wasFavorite);
      if (!mounted) return;
      if (!wasFavorite) {
        AppToast.show(context, '已收藏');
      }
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, wasFavorite ? '取消收藏失败' : '收藏失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([
        _favoriteService.favoriteStates,
        _favoriteService.pendingIds,
      ]),
      builder: (context, _) {
        final isFavorite =
            song != null &&
            _favoriteService.favoriteState(song.id, fallback: song.isFavorite);
        final isPending =
            song != null && _favoriteService.pendingIds.value.contains(song.id);
        return IconButton(
          tooltip: isFavorite ? '取消收藏' : '收藏',
          visualDensity: widget.visualDensity,
          padding: widget.padding,
          constraints: widget.constraints,
          icon: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: isFavorite
                ? scheme.error
                : scheme.onSurface.withValues(alpha: 0.72),
            size: widget.iconSize,
          ),
          onPressed: song == null || isPending ? null : _toggleFavorite,
        );
      },
    );
  }
}

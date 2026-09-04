import 'package:flutter/material.dart';

import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import 'now_playing_screen.dart';
import 'player_controller.dart';

/// Полоска плеера над нижними вкладками. Видна, когда что-то загружено.
/// Тап по полоске открывает полный экран плеера.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: controller.now,
      builder: (context, now, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => SizeTransition(
            sizeFactor: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: now == null
              ? const SizedBox(width: double.infinity, key: ValueKey('mp-empty'))
              : _bar(context, now),
        );
      },
    );
  }

  Widget _bar(BuildContext context, NowPlaying now) {
    return Material(
          key: const ValueKey('mp-bar'),
          color: Afisha.surfaceHi,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()),
            ),
            child: Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Afisha.line)),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  CoverThumb(path: now.coverPath, size: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(now.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Afisha.ink, fontWeight: FontWeight.w600)),
                        if (now.artist.isNotEmpty)
                          Text(now.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: controller.playing,
                    builder: (context, playing, _) => IconButton(
                      onPressed: controller.toggle,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Afisha.lime),
                      iconSize: 32,
                    ),
                  ),
                  IconButton(
                    onPressed: controller.next,
                    icon: const Icon(Icons.skip_next, color: Afisha.ink),
                    iconSize: 28,
                  ),
                ],
              ),
            ),
          ),
        );
  }
}

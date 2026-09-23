import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import 'now_playing_screen.dart';
import 'player_controller.dart';

/// Плашка плеера над нижними вкладками. Видна, когда что-то загружено.
/// Тап по плашке открывает полный экран плеера (выезжает снизу, как в Apple
/// Music). Оформление «как у Apple» (Alex TG 20345, 21.09.2026): скруглённая
/// серая плашка с небольшим отступом от краёв, обложка со скруглением 8,
/// значки «play / пауза / вперёд» из набора Cupertino.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: controller.now,
      builder: (context, now, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: const Cubic(0.32, 0.72, 0, 1),
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
    return Padding(
      key: const ValueKey('mp-bar'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Material(
        color: Afisha.groupHi,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            CupertinoPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => const NowPlayingScreen(),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              children: [
                // Тот же тег Hero, что у обложки полного плеера
                // (player_view.dart, _coverArea) — при открытии обложка
                // «вырастает» с этого места, а не пропадает/появляется другая
                // (Опус-ревью «Поток» 23.09.2026, пункт 12, «как в Apple Music»).
                Hero(
                  tag: 'player-cover',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CoverThumb(path: now.coverPath, url: coverUrlFor(now.id), size: 42),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(now.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Afisha.ink,
                              fontSize: 15,
                              letterSpacing: -0.3,
                              fontWeight: FontWeight.w600)),
                      if (now.artist.isNotEmpty)
                        Text(now.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Afisha.inkDim, fontSize: 12.5, letterSpacing: -0.1)),
                    ],
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: controller.playing,
                  builder: (context, playing, _) => IconButton(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      controller.toggle();
                    },
                    icon: Icon(playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                        color: Afisha.ink),
                    iconSize: 26,
                  ),
                ),
                IconButton(
                  onPressed: controller.next,
                  icon: const Icon(CupertinoIcons.forward_fill, color: Afisha.ink),
                  iconSize: 26,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

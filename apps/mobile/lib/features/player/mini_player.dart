import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
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

  void _open(BuildContext context) => Navigator.of(context).push(NowPlayingScreen.route());

  // 26.09.2026 (разбор Gemini «Моя музыка», Alex «9 делай»): плавающая стеклянная
  // плашка 64pt, скругление 20, отступы 16; открывается и тапом, и свайпом вверх
  // (плашка идёт за пальцем, отпустил выше — открывается плеер, обложка «перетекает»
  // через Hero).
  Widget _bar(BuildContext context, NowPlaying now) {
    return Padding(
      key: const ValueKey('mp-bar'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: _SwipeUpToOpen(
        onOpen: () => _open(context),
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(context),
            child: SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                child: Row(
                  children: [
                    // Тот же тег Hero, что у обложки полного плеера
                    // (player_view.dart, _coverArea) — при открытии обложка
                    // «вырастает» с этого места (Опус-ревью «Поток» 23.09.2026, п. 12).
                    Hero(
                      tag: 'player-cover',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CoverThumb(path: now.coverPath, url: coverUrlFor(now.id), size: 48),
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
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          controller.toggle();
                        },
                        icon: Icon(playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                            color: Afisha.ink),
                        iconSize: 28,
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: controller.next,
                      icon: const Icon(CupertinoIcons.forward_fill, color: Afisha.ink),
                      iconSize: 26,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Плашка идёт за пальцем вверх (до 60pt, с «резинкой»); отпустил выше 40pt или
/// смахнул быстро — открывается плеер; иначе пружинит на место.
class _SwipeUpToOpen extends StatefulWidget {
  const _SwipeUpToOpen({required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<_SwipeUpToOpen> createState() => _SwipeUpToOpenState();
}

class _SwipeUpToOpenState extends State<_SwipeUpToOpen> with SingleTickerProviderStateMixin {
  late final AnimationController _dy = AnimationController.unbounded(vsync: this, value: 0);

  @override
  void dispose() {
    _dy.dispose();
    super.dispose();
  }

  void _back() => _dy.animateWith(
        SpringSimulation(const SpringDescription(mass: 1, stiffness: 220, damping: 24), _dy.value, 0, 0),
      );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        // вверх — отрицательное; чем дальше, тем туже («резинка»)
        final next = _dy.value + d.delta.dy * (1 - (_dy.value.abs() / 90).clamp(0.0, 0.8));
        _dy.value = next.clamp(-60.0, 0.0);
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dy.value < -40 || v < -500) {
          HapticFeedback.lightImpact();
          widget.onOpen();
        }
        _back();
      },
      onVerticalDragCancel: _back,
      child: AnimatedBuilder(
        animation: _dy,
        child: widget.child,
        builder: (_, child) => Transform.translate(offset: Offset(0, _dy.value), child: child),
      ),
    );
  }
}

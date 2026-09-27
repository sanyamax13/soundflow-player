import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import 'player_view.dart';

/// Полноэкранный плеер, открытый поверх текущего экрана (тап по мини-плееру).
/// Само тело — общее с вкладкой «Поток», см. player_view.dart.
///
/// «Живое» закрытие (27.09.2026, разбор Gemini и Алисы, Alex «делай»): тянешь вниз за шапку или
/// обложку — плеер едет за пальцем, чуть уменьшается, скругляет углы, под ним проступает экран,
/// с которого открыли. Утянул на 35% высоты (на этом месте — короткий тик вибрацией) или смахнул
/// быстрее 1000 точек/с — закрывается; иначе пружиной назад.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  /// Выезжает снизу; прозрачный маршрут — чтобы при перетягивании был виден экран под плеером.
  static Route<void> route() => PageRouteBuilder<void>(
        opaque: false,
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, _, _) => const NowPlayingScreen(),
        transitionsBuilder: (_, anim, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
          child: child,
        ),
      );

  static const closeShare = 0.35;
  static const closeVelocity = 1000.0;

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _y = AnimationController.unbounded(vsync: this, value: 0);
  bool _pastLine = false;
  bool _closing = false;

  @override
  void dispose() {
    _y.dispose();
    super.dispose();
  }

  double get _h => MediaQuery.sizeOf(context).height;

  void _drag(double dy) {
    if (_closing) return;
    _y.stop();
    _y.value = (_y.value + dy).clamp(0.0, _h);
    final past = _y.value >= _h * NowPlayingScreen.closeShare;
    if (past && !_pastLine) HapticFeedback.mediumImpact(); // «отпусти — закроется»
    _pastLine = past;
  }

  void _dragEnd(double velocity) {
    if (_closing) return;
    if (_y.value >= _h * NowPlayingScreen.closeShare || velocity > NowPlayingScreen.closeVelocity) {
      _close();
    } else {
      _pastLine = false;
      _y.animateWith(SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 260, damping: 26), _y.value, 0, -velocity));
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerView(onDismiss: _close, onDismissDrag: _drag, onDismissDragEnd: _dragEnd);
    return AnimatedBuilder(
      animation: _y,
      child: Scaffold(backgroundColor: Afisha.bg, body: player),
      builder: (context, child) {
        final t = (_y.value / _h).clamp(0.0, 1.0);
        // Дерево одно и то же и в покое (t = 0), иначе плеер пересоздавался бы на первом кадре жеста.
        return Stack(
          children: [
            // Экран под плеером проступает по мере перетягивания.
            Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: 0.6 * (1 - t / 0.6).clamp(0.0, 1.0)))),
            Transform.translate(
              offset: Offset(0, _y.value),
              child: Transform.scale(
                scale: 1 - 0.1 * (t / 0.5).clamp(0.0, 1.0),
                alignment: Alignment.topCenter,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32 * (t / 0.1).clamp(0.0, 1.0)),
                  clipBehavior: t == 0 ? Clip.none : Clip.antiAlias,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

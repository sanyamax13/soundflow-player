import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Полоса «Жидкое стекло» (вариант 4 из пяти, Alex TG 22574, 28.09.2026): стеклянная дорожка
/// (полупрозрачная, со светлой кромкой), лаймовая заливка до играющего места, по заливке бежит
/// белый блик — его скорость идёт от темпа песни ([t] — «время пляски» полосы, см.
/// DotMatrixSeek: в тихих местах медленно, в припеве быстрее); на ударе баса ([pulse] 0..1)
/// край заливки чуть подаётся вперёд.
class GlassSeekPainter extends CustomPainter {
  const GlassSeekPainter({required this.progress, required this.t, required this.pulse});

  final double progress;
  final double t;
  final double pulse;

  static const _h = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final top = (size.height - _h) / 2;
    final r = const Radius.circular(_h / 2);
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, _h), r);
    canvas.drawRRect(track, Paint()..color = Colors.white.withValues(alpha: 0.08));
    canvas.drawRRect(
        track,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.18));

    final fw = math.min(size.width, math.max(_h, size.width * progress + 2 * pulse));
    final fill = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, fw, _h), r);
    canvas.save();
    canvas.clipRRect(fill);
    canvas.drawRect(fill.outerRect, Paint()..color = Afisha.lime);
    // блик: проходит заливку за 2 «секунды пляски»
    final sweep = (t * 0.5 % 1) * (fw + 120) - 60;
    final glint = Rect.fromLTWH(sweep - 40, top, 80, _h);
    canvas.drawRect(
        fill.outerRect,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.75),
            Colors.white.withValues(alpha: 0),
          ]).createShader(glint));
    // стеклянная кромка сверху
    canvas.drawRect(Rect.fromLTWH(0, top + 2, fw, 2), Paint()..color = Colors.white.withValues(alpha: 0.35));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GlassSeekPainter old) => true;
}

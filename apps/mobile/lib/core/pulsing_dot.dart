import 'package:flutter/material.dart';

/// Пульсирующая точка-индикатор состояния (Alex TG 25.09.2026, по разбору
/// Gemini — «живая панель» для Сервера/Настроек вместо списка строк):
/// дышит мягким свечением, зелёная = всё хорошо, любой другой цвет — для
/// прочих состояний (например, недоступен — красная).
class PulsingStatusDot extends StatefulWidget {
  const PulsingStatusDot({super.key, this.color = Colors.greenAccent, this.size = 12});

  final Color color;
  final double size;

  @override
  State<PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<PulsingStatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _a = Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 2)],
          ),
        ),
      );
}

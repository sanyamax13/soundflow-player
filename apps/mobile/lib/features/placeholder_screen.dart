import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Заглушка вкладки на этапе каркаса. Настоящий экран приедет своим шагом.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Afisha.line),
            const SizedBox(height: 12),
            Text('$title — скоро', style: const TextStyle(color: Afisha.inkDim)),
          ],
        ),
      ),
    );
  }
}

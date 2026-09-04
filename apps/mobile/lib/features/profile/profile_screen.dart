import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Профиль: статистика, синхронизация, настройки. Пока заглушки —
/// содержимое приедет своими шагами.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        children: const [
          _Row(icon: Icons.sync, title: 'Синхронизация', subtitle: 'скоро'),
          _Row(icon: Icons.bar_chart, title: 'Статистика', subtitle: 'скоро'),
          _Row(icon: Icons.settings_outlined, title: 'Настройки', subtitle: 'скоро'),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Afisha.inkDim),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(color: Afisha.inkDim)),
      trailing: const Icon(Icons.chevron_right, color: Afisha.line),
    );
  }
}

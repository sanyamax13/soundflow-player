import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../admin/admin_screen.dart';
import '../library/library_screen.dart';
import '../removed/removed_screen.dart';

/// Профиль: синхронизация, статистика, настройки. Статистика и настройки —
/// заглушки, приедут своими шагами.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        children: [
          _Row(
            icon: Icons.download_outlined,
            title: 'Библиотека',
            subtitle: 'докачать музыку с сервера',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LibraryScreen()),
            ),
          ),
          _Row(
            icon: Icons.auto_delete_outlined,
            title: 'Убранные',
            subtitle: 'что удалено и сколько места освободилось',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RemovedScreen()),
            ),
          ),
          _Row(
            icon: Icons.dns_outlined,
            title: 'Сервер',
            subtitle: 'состояние, синхронизация, устройства, события',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
            ),
          ),
          const _Row(icon: Icons.settings_outlined, title: 'Настройки', subtitle: 'скоро'),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Afisha.inkDim),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(color: Afisha.inkDim)),
      trailing: const Icon(Icons.chevron_right, color: Afisha.line),
      onTap: onTap,
    );
  }
}

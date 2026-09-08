import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/crash_log.dart';
import '../../core/theme.dart';
import '../admin/admin_screen.dart';
import '../library/library_screen.dart';
import '../removed/removed_screen.dart';
import 'server_url_screen.dart';

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
          const _CrashCard(),
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
          _Row(
            icon: Icons.lan_outlined,
            title: 'Адрес сервера',
            subtitle: apiBase.replaceFirst('http://', ''),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ServerUrlScreen()),
            ),
          ),
          const _Row(icon: Icons.settings_outlined, title: 'Настройки', subtitle: 'скоро'),
        ],
      ),
    );
  }
}

/// Показывается только если в прошлый раз приложение упало (Alex TG 19028).
/// Тап — весь текст сбоя: можно прочитать, отправить на компьютер, убрать.
class _CrashCard extends ConsumerStatefulWidget {
  const _CrashCard();

  @override
  ConsumerState<_CrashCard> createState() => _CrashCardState();
}

class _CrashCardState extends ConsumerState<_CrashCard> {
  String? _text;

  @override
  void initState() {
    super.initState();
    CrashLog.read().then((t) {
      if (mounted) setState(() => _text = t);
    });
  }

  Future<void> _open() async {
    final text = _text;
    if (text == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Последний сбой'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await ref
                    .read(apiProvider)
                    .reportCrash(await ref.read(syncProvider).deviceId(), text);
                messenger.showSnackBar(
                    const SnackBar(content: Text('Отправлено на компьютер')));
              } catch (_) {
                messenger.showSnackBar(
                    const SnackBar(content: Text('Компьютер сейчас недоступен')));
              }
            },
            child: const Text('Отправить на компьютер'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await CrashLog.clear();
              if (mounted) setState(() => _text = null);
            },
            child: const Text('Убрать'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    final firstLines = text.split('\n').take(3).join('\n');
    return Container(
      color: const Color(0x33FF5252),
      child: ListTile(
        leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF5252)),
        title: const Text('Приложение падало'),
        subtitle: Text(firstLines, style: const TextStyle(color: Afisha.inkDim)),
        trailing: const Icon(Icons.chevron_right, color: Afisha.line),
        onTap: _open,
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

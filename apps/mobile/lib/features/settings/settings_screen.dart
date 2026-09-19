import 'package:flutter/material.dart';

import '../../core/app_log.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../profile/server_url_screen.dart';

/// Настройки — вынесено из Профиля (Alex TG 14.09.2026: «в профиле только
/// статистику, а всё что настройки касается — в настройки»). Пока минимально:
/// сюда переехал только «Адрес сервера» (настройка в чистом виде) и добавился
/// журнал. Остальные пункты Профиля («Скачать музыку», «Убранные», «Сервер»,
/// «О программе») намеренно оставлены на месте — Alex попросил не тащить
/// сразу большую переделку, разберём отдельно позже.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          const _LogCard(),
          _Row(
            icon: Icons.lan_outlined,
            title: 'Адрес сервера',
            subtitle: apiBase.replaceFirst('http://', ''),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ServerUrlScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

/// Журнал реальных задержек на этом телефоне (радио и т.д.) — Alex TG
/// 14.09.2026: «делай полное логирование... какая реальность задержка идёт у
/// меня, а не с компьютера», «поставь лимит, чтобы не было огромных
/// списков» (см. core/app_log.dart — хранит только последние 3 часа).
class _LogCard extends StatefulWidget {
  const _LogCard();

  @override
  State<_LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<_LogCard> {
  String? _text;

  @override
  void initState() {
    super.initState();
    AppLog.read().then((t) {
      if (mounted) setState(() => _text = t);
    });
  }

  Future<void> _open() async {
    final text = _text ?? 'Журнал пока пуст — нажми радио или сделай что-нибудь в приложении.';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Журнал задержек'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          if (_text != null)
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                AppLog.share(text);
              },
              child: const Text('Отправить в Телеграм'),
            ),
          if (_text != null)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await AppLog.clear();
                if (mounted) setState(() => _text = null);
              },
              child: const Text('Очистить'),
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
    return ListTile(
      leading: const Icon(Icons.receipt_long_outlined, color: Afisha.inkDim),
      title: const Text('Журнал задержек'),
      subtitle: Text(
        _text == null ? 'пока пусто' : 'есть записи за последние часы — тапни, чтобы посмотреть',
        style: const TextStyle(color: Afisha.inkDim),
      ),
      trailing: const Icon(Icons.chevron_right, color: Afisha.line),
      onTap: _open,
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

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../core/app_log.dart';
import '../../core/config.dart';
import '../../core/theme.dart';
import '../profile/server_url_screen.dart';
import 'remote_access_screen.dart';

/// Настройки — вынесено из Профиля (Alex TG 14.09.2026: «в профиле только
/// статистику, а всё что настройки касается — в настройки»). Пока минимально:
/// сюда переехал только «Адрес сервера» (настройка в чистом виде) и добавился
/// журнал. Остальные пункты Профиля («Скачать музыку», «Сервер», «О программе»)
/// намеренно оставлены на месте — Alex попросил не тащить сразу большую
/// переделку, разберём отдельно позже. («Убранные» с телефона убраны 19.09.2026,
/// Alex TG 19943: их знает только программа на компьютере.)
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 25.09.2026 (по разбору Gemini, Alex «да меняй всё»): было в серых
    // карточках-плашках («как Настройки iPhone») — строки лежат прямо на
    // фоне, разделены только отступом и тонкой линией, покрупнее шрифт.
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          _row(
            icon: CupertinoIcons.wifi,
            iconColor: Afisha.blue,
            title: 'Адрес сервера',
            subtitle: apiBase.replaceFirst('http://', ''),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ServerUrlScreen()),
            ),
          ),
          _divider(),
          _row(
            icon: CupertinoIcons.globe,
            iconColor: Afisha.green,
            title: 'Удалённый доступ',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RemoteAccessScreen()),
            ),
          ),
          _divider(),
          const _LogCard(),
        ],
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
      );
}

Widget _row({
  required IconData icon,
  required Color iconColor,
  required String title,
  String? subtitle,
  required VoidCallback onTap,
}) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13)),
                  ],
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_forward, color: Colors.white.withValues(alpha: 0.3), size: 16),
          ],
        ),
      ),
    );

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
    final text = _text ?? 'Журнал пока пуст — включите радио или сделайте что-нибудь в приложении.';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Журнал'),
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
    return _row(
      icon: CupertinoIcons.doc_text,
      iconColor: Afisha.gray,
      title: 'Журнал',
      subtitle: _text == null ? 'пока пусто' : 'есть записи за последние часы — нажмите, чтобы посмотреть',
      onTap: _open,
    );
  }
}

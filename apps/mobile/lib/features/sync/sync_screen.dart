import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';

/// Карточка «Синхронизация»: сколько событий ждут отправки, когда синхронились
/// в последний раз, кнопка отправить сейчас. Отправка — только руками
/// (дома по Wi-Fi); авто-синк по сети — потом.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  int? _pending;
  DateTime? _last;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pending == null) _load();
  }

  Future<void> _load() async {
    final sync = AppScope.of(context).sync;
    final p = await sync.pendingCount();
    final l = await sync.lastSyncAt();
    if (!mounted) return;
    setState(() {
      _pending = p;
      _last = l;
    });
  }

  Future<void> _run() async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = (await scope.downloads.summary()).bytes;
      final r = await scope.sync.sync(musicBytes: bytes);
      messenger.showSnackBar(SnackBar(
        content: Text(r.sent == 0 ? 'Новых событий не было' : 'Отправлено событий: ${r.sent}'),
      ));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Сервер не ответил')));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  String _fmt(DateTime? d) {
    if (d == null) return 'ещё не было';
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            pending == null
                ? '…'
                : pending == 0
                    ? 'Всё отправлено'
                    : 'Ждут отправки: $pending',
            style: const TextStyle(fontSize: 22, color: Afisha.ink),
          ),
          const SizedBox(height: 8),
          Text('Последняя синхронизация: ${_fmt(_last)}',
              style: const TextStyle(color: Afisha.inkDim)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_busy || pending == null) ? null : _run,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Синхронизировать сейчас'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Лайки, удаления и что слушал копятся на телефоне и работают без сети. '
            'Дома по кнопке уходят на сервер. Одно и то же событие второй раз не задвоится.',
            style: TextStyle(color: Afisha.inkDim, height: 1.4),
          ),
        ],
      ),
    );
  }
}

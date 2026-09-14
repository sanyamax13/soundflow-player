import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/net_hint.dart';
import '../../core/theme.dart';
import 'blocklist_screen.dart';

/// «Сервер» — упрощено до того, что реально нужно Alex на ЭТОМ экране
/// (Опус-ревью телефона 14.09.2026, пункт 8): связь с компьютером,
/// синхронизация, список «больше не качать». Версии Go, миграции, сырые виды
/// событий, ID устройств и лог сервера убраны — это разработческая панель,
/// которая только пугала техническим видом и дублирует то, что теперь
/// показывает само окно программы на компьютере (серверный Опус-ревью того
/// же дня). PIN нет: плеер личный, сервер в домашней сети.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  bool _loading = true;
  bool _reachable = false;

  int? _pending;
  DateTime? _lastSync;
  bool _syncBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    final sync = ref.read(syncProvider);
    setState(() => _loading = true);
    // Локальные цифры синка — всегда, даже если сервер недоступен.
    try {
      final p = await sync.pendingCount();
      final l = await sync.lastSyncAt();
      if (mounted) {
        setState(() {
          _pending = p;
          _lastSync = l;
        });
      }
    } catch (_) {}
    try {
      await api.adminStatus();
      if (!mounted) return;
      setState(() {
        _reachable = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reachable = false;
        _loading = false;
      });
    }
  }

  Future<void> _syncNow() async {
    final downloads = ref.read(downloadsProvider);
    final sync = ref.read(syncProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncBusy = true);
    try {
      final bytes = (await downloads.summary()).bytes;
      final r = await sync.sync(musicBytes: bytes);
      // Кнопка должна делать ПОЛНЫЙ обмен: отдать события И забрать/выполнить
      // план, который собрали в окне на компе (Alex 08.09.2026 — жал
      // «Синхронизировать сейчас», а план не подхватывался, качалось только
      // по таймеру раз в 3 мин).
      final plan = await downloads.applyPendingPlan();
      final parts = <String>[
        if (r.sent > 0) 'отправлено ${r.sent}',
        if (plan.added > 0) 'скачано ${plan.added}',
        if (plan.removed > 0) 'убрано ${plan.removed}',
        if (plan.failed > 0) 'не вышло ${plan.failed}',
      ];
      messenger.showSnackBar(SnackBar(
        content: Text(parts.isEmpty ? 'Всё уже синхронизировано' : parts.join(', ')),
      ));
    } catch (_) {
      if (mounted) showServerUnreachableSnackBar(context, messenger);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сервер')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _body(),
      ),
    );
  }

  Widget _connectivityRow() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle,
                    color: _reachable ? Afisha.lime : Colors.redAccent, size: 12),
                const SizedBox(width: 8),
                Text(
                  _reachable ? 'Компьютер на связи' : 'Компьютер недоступен',
                  style: const TextStyle(fontSize: 16, color: Afisha.ink),
                ),
              ],
            ),
            if (!_reachable) ...[
              const SizedBox(height: 6),
              const Text(kServerUnreachableHint,
                  style: TextStyle(color: Afisha.inkDim, height: 1.35, fontSize: 12.5)),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Проверить связь')),
            ],
          ],
        ),
      );

  Widget _syncBlock() {
    final pending = _pending;
    String fmt(DateTime? d) {
      if (d == null) return 'ещё не было';
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pending == null
                ? '…'
                : pending == 0
                    ? 'Всё отправлено'
                    : 'Ждут отправки: $pending',
            style: const TextStyle(fontSize: 20, color: Afisha.ink),
          ),
          const SizedBox(height: 4),
          Text('Последняя синхронизация: ${fmt(_lastSync)}',
              style: const TextStyle(color: Afisha.inkDim)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (_syncBusy || pending == null) ? null : _syncNow,
            child: _syncBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Синхронизировать сейчас'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Лайки, удаления и что слушал копятся на телефоне и работают без '
            'сети. Уходят на сервер сами, как появляется связь. Кнопка — если '
            'нужно прямо сейчас.',
            style: TextStyle(color: Afisha.inkDim, height: 1.35, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _section('Связь с компьютером'),
        _connectivityRow(),
        _section('Синхронизация'),
        _syncBlock(),
        _section('Больше не качать'),
        ListTile(
          dense: true,
          title: const Text('Список «больше не качать»'),
          subtitle: const Text('удалённые песни, которые сервер не предложит снова',
              style: TextStyle(color: Afisha.inkDim)),
          trailing: const Icon(Icons.chevron_right, color: Afisha.line),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const BlocklistScreen()),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: Afisha.lime, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
      );
}

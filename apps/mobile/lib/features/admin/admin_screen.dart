import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/net_hint.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';

/// «Сервер» — упрощено до того, что реально нужно Alex на ЭТОМ экране
/// (Опус-ревью телефона 14.09.2026, пункт 8): связь с компьютером и
/// синхронизация. Версии Go, миграции, сырые виды событий, ID устройств и лог
/// сервера убраны — это разработческая панель, которая только пугала
/// техническим видом и дублирует то, что теперь показывает само окно
/// программы на компьютере (серверный Опус-ревью того же дня). PIN нет: плеер
/// личный, сервер в домашней сети. Список «больше не качать» с 19.09.2026 на
/// телефоне не показывается (Alex TG 19943: «все в программу и все скрыто»):
/// его знает только программа на компьютере.
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
          const SizedBox(height: 8),
          const Text(
            'Лайки, удаления и что слушал копятся на телефоне и работают без '
            'сети. Уходят на компьютер сами, как только появляется связь.',
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
        _section('Что уходит на компьютер'),
        _syncBlock(),
        _section('Опасно'),
        _resetBlock(),
        const SizedBox(height: 24),
      ],
    );
  }

  // Alex TG 15.09.2026: «сделай кнопку полный сброс, что бы как первый раз
  // установил и без музыки». Стирает музыку/лайки/историю на ЭТОМ телефоне;
  // адрес сервера и id телефона не трогает (иначе на компе появится ещё одна
  // запись-«призрак» устройства — та самая проблема, что только что чинили).
  bool _resetBusy = false;

  Widget _resetBlock() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Сотрёт всю музыку, лайки и историю на ЭТОМ телефоне — будет как '
            'после первой установки. На сервере (комп) и на других '
            'устройствах ничего не меняется. Отменить нельзя.',
            style: TextStyle(color: Afisha.inkDim, height: 1.35, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: _resetBusy ? null : _confirmReset,
            child: _resetBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Полный сброс'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Полный сброс?'),
        content: const Text(
          'Удалит всю скачанную музыку, лайки и историю на этом телефоне. '
          'Отменить нельзя.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Стереть всё', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final downloads = ref.read(downloadsProvider);
    setState(() => _resetBusy = true);
    try {
      await downloads.fullReset();
      Notice.show('Готово', subtitle: 'Телефон как новый', kind: NoticeKind.done);
    } catch (e) {
      Notice.show('Не вышло', subtitle: '$e', kind: NoticeKind.error);
    } finally {
      if (mounted) setState(() => _resetBusy = false);
      await _load();
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: Afisha.lime, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
      );
}

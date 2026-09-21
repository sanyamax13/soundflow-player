import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
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

  Widget _connectivityRow() => AppleRow(
    icon: CupertinoIcons.desktopcomputer,
    iconBg: _reachable ? Afisha.green : Afisha.red,
    title: _reachable ? 'Компьютер на связи' : 'Компьютер недоступен',
    subtitle: _reachable ? null : kServerUnreachableHint,
  );

  String _syncTitle() {
    final pending = _pending;
    return pending == null
        ? '…'
        : pending == 0
        ? 'Всё отправлено'
        : 'Ждут отправки: $pending';
  }

  String _lastSyncText() {
    String fmt(DateTime? d) {
      if (d == null) return 'ещё не было';
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
    }

    return 'Последняя синхронизация: ${fmt(_lastSync)}';
  }

  Widget _body() {
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        AppleSection(
          header: 'Связь с компьютером',
          dividerInset: 58,
          children: [
            _connectivityRow(),
            if (!_reachable) AppleRow(title: 'Проверить связь', onTap: _load),
          ],
        ),
        const SizedBox(height: 24),
        AppleSection(
          header: 'Что уходит на компьютер',
          footer:
              'Лайки, удаления и что слушал копятся на телефоне и работают без '
              'сети. Уходят на компьютер сами, как только появляется связь.',
          children: [AppleRow(title: _syncTitle(), subtitle: _lastSyncText())],
        ),
        const SizedBox(height: 24),
        // «Полный сброс» лежал рядом с обычной синхронизацией, в два тапа от «стереть всю музыку» (ревизия 20.09.2026,
        // пункт «убрать вглубь»): теперь спрятан за «Показать опасное», случайно не нажмёшь.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: Afisha.groupBg,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('danger-zone'),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                iconColor: Afisha.inkDim,
                collapsedIconColor: Afisha.inkDim,
                title: const Text(
                  'Показать опасное',
                  style: TextStyle(
                    color: Afisha.inkDim,
                    fontSize: 17,
                    letterSpacing: -0.4,
                  ),
                ),
                children: [_resetBlock()],
              ),
            ),
          ),
        ),
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Сотрёт всю музыку, лайки и историю на ЭТОМ телефоне — будет как '
            'после первой установки. На сервере (комп) и на других '
            'устройствах ничего не меняется. Отменить нельзя.',
            style: TextStyle(color: Afisha.inkDim, height: 1.35, fontSize: 13),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Afisha.red,
                minimumSize: const Size(0, 46),
                side: BorderSide(
                  color: Afisha.red.withValues(alpha: 0.5),
                  width: 0.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _resetBusy ? null : _confirmReset,
              child: _resetBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Полный сброс'),
            ),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Стереть всё',
              style: TextStyle(color: Afisha.red),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final downloads = ref.read(downloadsProvider);
    setState(() => _resetBusy = true);
    try {
      await downloads.fullReset();
      Notice.show(
        'Готово',
        subtitle: 'Телефон как новый',
        kind: NoticeKind.done,
      );
    } catch (e) {
      Notice.show('Не вышло', subtitle: '$e', kind: NoticeKind.error);
    } finally {
      if (mounted) setState(() => _resetBusy = false);
      await _load();
    }
  }
}

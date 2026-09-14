import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/net_hint.dart';
import '../../core/theme.dart';

/// «Убранные» — что удалено из «Моей музыки»: сколько песен, сколько места
/// освободилось, по какой причине. Заменяет «Корзину» (Alex TG 18689,
/// 07.09.2026): вернуть-из-корзины больше нет, «не нравится» стирает сразу,
/// поэтому вместо мусорки — статистика. Работает офлайн (локальный журнал),
/// «Скачать заново» требует домашней сети.
class RemovedScreen extends ConsumerStatefulWidget {
  const RemovedScreen({super.key});

  @override
  ConsumerState<RemovedScreen> createState() => _RemovedScreenState();
}

/// Человеческие названия причин удаления (ключи — см. player_view.dart и
/// my_music_screen.dart).
const _reasonLabels = <String, String>{
  'dislike': 'Не нравится',
  'bad_quality': 'Плохое качество',
  'not_music': 'Не музыка',
  'tired': 'Надоела',
  'wrong_version': 'Не та версия',
  'broken_tag': 'Имя не читалось',
  'other': 'Другая причина',
  '': 'Без причины',
};

String _reasonLabel(String key) => _reasonLabels[key] ?? key;

class _RemovedStateData {
  _RemovedStateData(this.rows, this.total, this.byReason);
  final List<Map<String, Object?>> rows;
  final ({int count, int bytes}) total;
  final Map<String, ({int count, int bytes})> byReason;
}

class _RemovedScreenState extends ConsumerState<RemovedScreen> {
  _RemovedStateData? _data;
  final Set<String> _busy = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_data == null) _load();
  }

  Future<void> _load() async {
    final d = ref.read(downloadsProvider);
    final rows = await d.removedList();
    final total = await d.removedTotals();
    final byReason = await d.removedByReason();
    if (!mounted) return;
    setState(() => _data = _RemovedStateData(rows, total, byReason));
  }

  String _mb(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
    return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  }

  String _songWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'песня';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return 'песни';
    return 'песен';
  }

  Future<void> _redownload(Map<String, Object?> r) async {
    final id = '${r['id']}';
    setState(() => _busy.add(id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(downloadsProvider).redownload(
            id,
            title: '${r['title']}',
            artist: '${r['artist']}',
          );
      messenger.showSnackBar(
          SnackBar(content: Text('Скачал заново «${r['title']}»')));
      await _load();
    } catch (_) {
      if (mounted) showServerUnreachableSnackBar(context, messenger, lead: 'Не вышло скачать заново');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить список?'),
        content: const Text(
            'Сотрётся только этот список и счётчики. Сама музыка уже удалена, '
            'её это не трогает.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Очистить')),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(downloadsProvider).removedClear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Убранные'),
        actions: [
          if (data != null && data.rows.isNotEmpty)
            IconButton(
                tooltip: 'Очистить список',
                onPressed: _clear,
                icon: const Icon(Icons.delete_sweep_outlined)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : data.rows.isEmpty
              ? const Center(
                  child: Text('Пока ничего не убрано',
                      style: TextStyle(color: Afisha.inkDim)))
              : _content(data),
    );
  }

  Widget _content(_RemovedStateData data) {
    final reasons = data.byReason.entries.toList();
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Убрано ${data.total.count} ${_songWord(data.total.count)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text('Освободилось ${_mb(data.total.bytes)}',
                  style: const TextStyle(color: Afisha.inkDim)),
            ],
          ),
        ),
        const Divider(height: 1, color: Afisha.line),
        // Разбивка по причине — каждая раскрывается в свои песни.
        for (final e in reasons)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: Text(_reasonLabel(e.key)),
              subtitle: Text(
                '${e.value.count} ${_songWord(e.value.count)}  ·  ${_mb(e.value.bytes)}',
                style: const TextStyle(color: Afisha.inkDim, fontSize: 12.5),
              ),
              childrenPadding: const EdgeInsets.only(bottom: 4),
              children: [
                for (final r in data.rows.where((x) => '${x['reason']}' == e.key))
                  _row(r),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(Map<String, Object?> r) {
    final id = '${r['id']}';
    final busy = _busy.contains(id);
    final bytes = (r['bytes'] as int?) ?? 0;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 24, right: 8),
      title: Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${r['artist']}  ·  ${_mb(bytes)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Afisha.inkDim, fontSize: 11.5)),
      trailing: busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              onPressed: () => _redownload(r),
              child: const Text('Скачать заново')),
    );
  }
}

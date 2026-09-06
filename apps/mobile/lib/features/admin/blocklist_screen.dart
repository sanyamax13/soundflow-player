import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';

/// Список «больше не качать» — удалённые в плеере треки + старый чёрный
/// список. По этим записям сервер не отдаёт трек в каталог и не качает
/// заново. Можно убрать запись по ошибке — тогда трек снова доступен
/// (файл, если был стёрт, скачается заново из источника). Alex 06.09.2026.
class BlocklistScreen extends ConsumerStatefulWidget {
  const BlocklistScreen({super.key});

  @override
  ConsumerState<BlocklistScreen> createState() => _BlocklistScreenState();
}

class _BlocklistScreenState extends ConsumerState<BlocklistScreen> {
  List<Map<String, dynamic>>? _items;
  final Set<String> _busy = {};

  // true — сервер не ответил (телефон вне домашней сети). Показываем понятное
  // сообщение вместо вечного колеса.
  bool _offline = false;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null && !_loading) _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    if (mounted) {
      setState(() {
        _items = null;
        _offline = false;
      });
    }
    try {
      final list = await ref
          .read(apiProvider)
          .blocklist()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() => _items = list);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _offline = true;
      });
    } finally {
      _loading = false;
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final key = '${row['key']}';
    setState(() => _busy.add(key));
    try {
      await ref.read(apiProvider).blocklistRemove(key);
      if (!mounted) return;
      setState(() {
        _busy.remove(key);
        _items = _items?.where((x) => x['key'] != key).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy.remove(key));
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не получилось — попробуй ещё раз')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Больше не качать'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : _offline
              ? _offlineBox()
              : items.isEmpty
              ? const Center(
                  child: Text('Список пуст',
                      style: TextStyle(color: Afisha.inkDim)),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('${items.length} в списке',
                            style: const TextStyle(
                                color: Afisha.inkDim, fontSize: 12.5)),
                      ),
                    ),
                    const Divider(height: 1, color: Afisha.line),
                    Expanded(
                      child: ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Afisha.line),
                        itemBuilder: (_, i) => _row(items[i]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _offlineBox() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: Afisha.inkDim, size: 40),
              const SizedBox(height: 14),
              const Text(
                'Сервер в домашней сети. Подключись к домашнему Wi-Fi, '
                'чтобы увидеть список.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Afisha.inkDim),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                  onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );

  Widget _row(Map<String, dynamic> row) {
    final key = '${row['key']}';
    final busy = _busy.contains(key);
    final artist = '${row['artist'] ?? ''}'.trim();
    final title = '${row['title'] ?? ''}'.trim();
    final label = [
      if (title.isNotEmpty) title,
      if (artist.isNotEmpty) artist,
    ].join(' — ');
    return ListTile(
      dense: true,
      title: Text(label.isEmpty ? key : label,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: row['in_catalog'] == true
          ? null
          : const Text('нет в каталоге',
              style: TextStyle(color: Afisha.inkDim, fontSize: 11)),
      trailing: busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: () => _remove(row), child: const Text('Убрать')),
    );
  }
}

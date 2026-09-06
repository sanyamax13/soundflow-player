import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';

/// «Корзина»: песни, которые сервер убрал у себя ДО 06.09.2026 — их файлы
/// ещё лежат на сервере в отдельной папке, можно вернуть. С 06.09.2026 новые
/// удаления стираются сразу (Alex), сюда больше не попадают. Кнопка
/// «Очистить корзину» — стереть насовсем всё, что тут осталось.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  List<Map<String, dynamic>>? _items;
  final Set<String> _busy = {};

  // true — сервер не ответил (обычно телефон на мобильном интернете, а сервер
  // дома). Показываем понятное сообщение, а не бесконечное колесо.
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
          .trashList()
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

  bool _purging = false;

  Future<void> _purgeAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить корзину?'),
        content: const Text(
            'Всё, что сейчас в корзине, сотрётся с сервера насовсем и вернуть '
            'будет нельзя. Список «больше не качать» не меняется.'),
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
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _purging = true);
    try {
      final n = await ref.read(apiProvider).trashPurge();
      if (!mounted) return;
      setState(() {
        _purging = false;
        _items = const [];
      });
      messenger.showSnackBar(SnackBar(content: Text('Корзина очищена: удалено $n')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _purging = false);
      messenger.showSnackBar(
          const SnackBar(content: Text('Не получилось — попробуй ещё раз')));
    }
  }

  Future<void> _restore(Map<String, dynamic> t) async {
    final id = '${t['track_id']}';
    setState(() => _busy.add(id));
    try {
      await ref.read(apiProvider).trashRestore(id);
      if (!mounted) return;
      setState(() {
        _busy.remove(id);
        _items = _items?.where((x) => x['track_id'] != id).toList();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Вернул «${t['title']}» в каталог')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy.remove(id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Не получилось — попробуй ещё раз')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Корзина'),
        actions: [
          if ((items ?? const []).isNotEmpty)
            _purging
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Очистить корзину',
                    onPressed: _purgeAll,
                    icon: const Icon(Icons.delete_forever)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : _offline
              ? _offlineBox()
              : items.isEmpty
                  ? const Center(
                      child: Text('Пусто — ничего не убрано', style: TextStyle(color: Afisha.inkDim)),
                    )
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: Afisha.line),
                      itemBuilder: (_, i) => _row(items[i]),
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
                'чтобы увидеть корзину.',
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

  Widget _row(Map<String, dynamic> t) {
    final id = '${t['track_id']}';
    final busy = _busy.contains(id);
    return ListTile(
      title: Text('${t['title']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${t['artist']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: () => _restore(t), child: const Text('Вернуть')),
    );
  }
}

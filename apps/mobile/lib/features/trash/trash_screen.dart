import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';

/// «Корзина»: песни, которые сервер убрал у себя — удалил Alex на телефоне
/// (после синхронизации) или это оказался мусор (интервью, скит и т.п.,
/// см. чистку каталога). Файлы не стёрты насовсем, лежат на сервере в
/// специальной папке — можно вернуть.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<Map<String, dynamic>>? _items;
  final Set<String> _busy = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    try {
      final list = await AppScope.of(context).api.trashList();
      if (!mounted) return;
      setState(() => _items = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _items = const []);
    }
  }

  Future<void> _restore(Map<String, dynamic> t) async {
    final id = '${t['track_id']}';
    setState(() => _busy.add(id));
    try {
      await AppScope.of(context).api.trashRestore(id);
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
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
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

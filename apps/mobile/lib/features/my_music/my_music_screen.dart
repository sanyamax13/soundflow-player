import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/player_controller.dart';

/// «Моя музыка» — всё, что скачано на телефон. Сверху: сколько песен и
/// сколько занято. Переключатель Все/Избранное. У каждой песни: играть,
/// сердечко, удалить. Это же — инструмент посмотреть и почистить.
class MyMusicScreen extends StatefulWidget {
  const MyMusicScreen({super.key});

  @override
  State<MyMusicScreen> createState() => _MyMusicScreenState();
}

class _MyMusicScreenState extends State<MyMusicScreen> {
  bool _onlyFav = false;
  List<DownloadedTrack>? _items;
  int _count = 0;
  int _bytes = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _refresh();
  }

  Future<void> _refresh() async {
    final d = AppScope.of(context).downloads;
    final items = await d.list(onlyFavorite: _onlyFav);
    final s = await d.summary();
    if (!mounted) return;
    setState(() {
      _items = items;
      _count = s.count;
      _bytes = s.bytes;
    });
  }

  String _mb(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
  }

  Future<void> _play(DownloadedTrack t) => AppScope.of(context).player.playSingle(
        NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path),
      );

  Future<void> _toggleFav(DownloadedTrack t) async {
    await AppScope.of(context).downloads.setFavorite(t.id, !t.favorite);
    await _refresh();
  }

  Future<void> _delete(DownloadedTrack t) async {
    final downloads = AppScope.of(context).downloads;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Удалить «${t.title}»?'),
        content: const Text('Файл сотрётся с телефона. Скачать заново можно будет с сервера.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(dialogCtx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (yes != true) return;
    await downloads.delete(t.id);
    await _refresh();
  }

  Future<void> _addFromServer() async {
    final downloads = AppScope.of(context).downloads;
    List<Map<String, dynamic>> server;
    try {
      server = await downloads.serverTracks();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сервер не ответил')),
        );
      }
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Afisha.surface,
      builder: (sheetCtx) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('С сервера', style: TextStyle(color: Afisha.inkDim)),
          ),
          for (final t in server)
            ListTile(
              title: Text('${t['title']}'),
              subtitle: Text('${t['artist']}'),
              trailing: const Icon(Icons.download, color: Afisha.lime),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await downloads.download(t);
                await _refresh();
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Моя музыка'),
        actions: [
          IconButton(onPressed: _addFromServer, icon: const Icon(Icons.add)),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Flexible(
                  child: Text('$_count песен · ${_mb(_bytes)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Afisha.inkDim)),
                ),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Все')),
                    ButtonSegment(value: true, label: Text('Избранное')),
                  ],
                  selected: {_onlyFav},
                  onSelectionChanged: (s) {
                    setState(() => _onlyFav = s.first);
                    _refresh();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Afisha.line),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? _empty()
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: Afisha.line),
                        itemBuilder: (_, i) => _row(items[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _row(DownloadedTrack t) => ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${t.artist} · ${_mb(t.bytes)}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _mini(Icons.play_arrow, Afisha.lime, () => _play(t)),
            _mini(t.favorite ? Icons.favorite : Icons.favorite_border,
                t.favorite ? Afisha.lime : Afisha.inkDim, () => _toggleFav(t)),
            _mini(Icons.delete_outline, Afisha.inkDim, () => _delete(t)),
          ],
        ),
      );

  Widget _mini(IconData icon, Color color, VoidCallback onTap) => IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: color, size: 22),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      );

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Пока ничего не скачано', style: TextStyle(color: Afisha.inkDim)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _addFromServer, child: const Text('Добавить с сервера')),
          ],
        ),
      );
}

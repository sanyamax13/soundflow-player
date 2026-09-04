import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/now_playing_screen.dart';
import '../player/player_controller.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Умного подбора по звуку
/// и фильтров по жанрам здесь нет (следующие шаги).
class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key, this.onOpenLibrary});

  /// Перейти на вкладку «Моя музыка» (когда качать ещё нечего).
  final VoidCallback? onOpenLibrary;

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> {
  List<DownloadedTrack>? _items;
  bool _shuffle = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final items = await AppScope.of(context).downloads.list();
    if (!mounted) return;
    setState(() => _items = items);
  }

  List<NowPlaying> get _queue => [
        for (final t in _items ?? const <DownloadedTrack>[])
          NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path),
      ];

  Future<void> _listen({int startIndex = 0, bool? shuffle}) async {
    final q = _queue;
    if (q.isEmpty) return;
    await AppScope.of(context)
        .player
        .playQueue(q, startIndex: startIndex, shuffle: shuffle ?? _shuffle);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Поток')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? _empty()
              : _list(items),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.graphic_eq, color: Afisha.inkDim, size: 64),
              const SizedBox(height: 16),
              const Text('В Потоке пока пусто',
                  style: TextStyle(fontSize: 18, color: Afisha.ink)),
              const SizedBox(height: 8),
              const Text(
                'Скачай музыку во вкладке «Моя музыка» — Поток играет её без интернета.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Afisha.inkDim),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: widget.onOpenLibrary,
                child: const Text('Открыть «Мою музыку»'),
              ),
            ],
          ),
        ),
      );

  Widget _list(List<DownloadedTrack> items) {
    final player = AppScope.of(context).player;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _listen(),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_shuffle ? 'Слушать вперемешку' : 'Слушать по порядку'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Вперемешку',
                onPressed: () => setState(() => _shuffle = !_shuffle),
                icon: Icon(Icons.shuffle, color: _shuffle ? Afisha.lime : Afisha.inkDim),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${items.length} песен на телефоне',
                style: const TextStyle(color: Afisha.inkDim)),
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1, color: Afisha.line),
        Expanded(
          child: ValueListenableBuilder<NowPlaying?>(
            valueListenable: player.now,
            builder: (context, now, _) => ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: Afisha.line),
              itemBuilder: (_, i) {
                final t = items[i];
                final active = now?.id == t.id;
                return ListTile(
                  title: Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: active ? Afisha.lime : Afisha.ink)),
                  subtitle: Text(t.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Afisha.inkDim)),
                  trailing:
                      active ? const Icon(Icons.equalizer, color: Afisha.lime, size: 20) : null,
                  onTap: () => _listen(startIndex: i, shuffle: false),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

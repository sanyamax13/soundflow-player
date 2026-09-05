import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. С 05.09.2026 (просьба
/// Alex) это не список, а сразу полноэкранный плеер («вариант C»): открыл
/// вкладку — играет. Список убран целиком; переключить порядок песен можно
/// иконкой "перемешать" в самом плеере. Умного подбора по звуку и фильтров
/// по жанрам здесь нет (следующие шаги).
class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key, this.onOpenLibrary});

  /// Перейти на вкладку «Моя музыка» (когда качать ещё нечего).
  final VoidCallback? onOpenLibrary;

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> {
  List<DownloadedTrack>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final items = await AppScope.of(context).downloads.list();
    if (!mounted) return;
    setState(() => _items = items);
    final player = AppScope.of(context).player;
    // Уже что-то играет (пришли из «Моей музыки» и переключились сюда) —
    // не перебиваем. Иначе — заводим вперемешку сразу, не дожидаясь: экран
    // (PlayerView) сам покажет обложку и название, как только реально заиграет.
    if (items.isNotEmpty && player.now.value == null) {
      final queue = [
        for (final t in items)
          NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
      ];
      player.playQueue(queue, shuffle: true).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? _empty()
              : const PlayerView(),
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
}

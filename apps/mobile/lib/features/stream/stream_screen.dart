import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Открыл вкладку — сразу
/// полноэкранный плеер: обложка, название, полоска-волна и кнопки
/// ⏮ ▶ ⏭ — но на паузе. Музыка НЕ заводится сама (Alex 06.09.2026: «зачем её
/// запускать?»), играть начинает по нажатию play. Порядок песен —
/// вперемешку, переключается иконкой в самом плеере.
class StreamScreen extends ConsumerStatefulWidget {
  const StreamScreen({super.key, this.onOpenLibrary});

  /// Перейти на вкладку «Моя музыка» (когда качать ещё нечего).
  final VoidCallback? onOpenLibrary;

  @override
  ConsumerState<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends ConsumerState<StreamScreen> {
  List<DownloadedTrack>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final items = await ref.read(downloadsProvider).list();
    if (!mounted) return;
    setState(() => _items = items);
    // Уже что-то заряжено/играет (пришли из «Моей музыки») — не трогаем.
    // Иначе заряжаем всю библиотеку вперемешку НА ПАУЗЕ, чтобы вкладка сразу
    // была полноценным плеером (обложка, полоска, ⏮ ▶ ⏭), а не голой кнопкой
    // play. Не ждём — если аудио вдруг недоступно, просто останемся без
    // очереди, экран не залипнет.
    final player = ref.read(playerProvider);
    if (items.isNotEmpty && player.now.value == null) {
      final queue = [
        for (final t in items)
          NowPlaying(
              id: t.id,
              title: t.title,
              artist: t.artist,
              path: t.path,
              coverPath: t.coverPath),
      ];
      unawaited(player.playQueue(
        queue,
        startIndex: Random().nextInt(items.length),
        shuffle: true,
        autoplay: false,
      ));
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

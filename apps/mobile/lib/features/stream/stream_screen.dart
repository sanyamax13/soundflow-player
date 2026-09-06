import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/cover_backdrop.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Открыл вкладку — сразу
/// играет полноэкранный плеер, без промежуточного экрана с кнопкой «начать»
/// (Alex 06.09.2026: «сразу как полноценный плеер сделай, незачем
/// предупреждать» — отмена прежней просьбы 05.09 не заводить само).
/// Порядок песен переключается иконкой «перемешать» в самом плеере. Умного
/// подбора по звуку и фильтров по жанрам здесь пока нет.
class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key, this.onOpenLibrary});

  /// Перейти на вкладку «Моя музыка» (когда качать ещё нечего).
  final VoidCallback? onOpenLibrary;

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> {
  List<DownloadedTrack>? _items;
  // Одна песня «на витрине» для фона, пока звук ещё не завёлся (первые доли
  // секунды после открытия вкладки). Выбирается один раз при загрузке.
  DownloadedTrack? _preview;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final items = await AppScope.of(context).downloads.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _preview = items.isEmpty ? null : items[Random().nextInt(items.length)];
    });
    // Само заводим Поток при открытии вкладки — но только если вообще ничего
    // ещё не играет (не перебиваем песню, запущенную из «Моей музыки»).
    if (items.isNotEmpty && AppScope.of(context).player.now.value == null) {
      _start();
    }
  }

  /// Завести всю библиотеку вперемешку, начиная с показанной на фоне песни.
  void _start() {
    final items = _items;
    if (items == null || items.isEmpty) return;
    final queue = [
      for (final t in items)
        NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ];
    final start = _preview == null ? 0 : items.indexOf(_preview!);
    AppScope.of(context)
        .player
        .playQueue(queue, startIndex: start < 0 ? 0 : start, shuffle: true)
        .catchError((_) {});
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
              : PlayerView(emptyState: _warmup()),
    );
  }

  /// Кадр-заглушка на те доли секунды, пока звук заводится: та же обложка
  /// размытым фоном + кружок загрузки. Тап по экрану — повторить запуск, если
  /// вдруг не завелось (без надписей — Alex просил не «предупреждать»).
  Widget _warmup() {
    final t = _preview;
    return GestureDetector(
      onTap: _start,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (t == null)
            const ColoredBox(color: Afisha.bg)
          else
            CoverBackdrop(trackId: t.id, localPath: t.coverPath),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x66000000)),
          ),
          const Center(
            child: CircularProgressIndicator(color: Afisha.lime),
          ),
        ],
      ),
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

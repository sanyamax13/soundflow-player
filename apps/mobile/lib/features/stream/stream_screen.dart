import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/cover_backdrop.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Открыл вкладку — видно
/// полноэкранный плеер с обложкой и большой кнопкой play; музыка НЕ заводится
/// сама, играть начинает по нажатию (Alex 06.09.2026: «зачем её запускать?»).
/// Убрали только промежуточную строку «Слушать вперемешку — N песен» —
/// «незачем предупреждать» (Alex 06.09.2026). Порядок песен переключается
/// иконкой «перемешать» в самом плеере. Умного подбора по звуку здесь пока нет.
class StreamScreen extends ConsumerStatefulWidget {
  const StreamScreen({super.key, this.onOpenLibrary});

  /// Перейти на вкладку «Моя музыка» (когда качать ещё нечего).
  final VoidCallback? onOpenLibrary;

  @override
  ConsumerState<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends ConsumerState<StreamScreen> {
  List<DownloadedTrack>? _items;
  // Одна песня «на витрине» стартового экрана — чтобы вместо голого значка
  // play сразу было видно, что вот-вот заиграет. Выбирается один раз при
  // загрузке, не на каждую перерисовку.
  DownloadedTrack? _preview;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final items = await ref.read(downloadsProvider).list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _preview = items.isEmpty ? null : items[Random().nextInt(items.length)];
    });
  }

  /// Завести всю библиотеку вперемешку, начиная с показанной на витрине песни.
  /// Зовётся по нажатию кнопки play, само не запускается.
  void _start() {
    final items = _items;
    if (items == null || items.isEmpty) return;
    final queue = [
      for (final t in items)
        NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ];
    final start = _preview == null ? 0 : items.indexOf(_preview!);
    ref
        .read(playerProvider)
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
              : PlayerView(emptyState: _startView()),
    );
  }

  /// Стартовый вид вкладки: тот же полноэкранный плеер (обложка целиком +
  /// размытая копия фоном), название под ней и большая кнопка play. До и после
  /// нажатия экран выглядит одинаково, без скачка. Строки «Слушать вперемешку
  /// — N песен» здесь нет (Alex 06.09.2026).
  Widget _startView() {
    final t = _preview;
    final placeholder = Container(
      color: Afisha.surfaceHi,
      child: const Center(
        child: Icon(Icons.graphic_eq, color: Afisha.lime, size: 96),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        t == null
            ? placeholder
            : CoverBackdrop(trackId: t.id, localPath: t.coverPath),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Color(0xB3000000),
              ],
              stops: [0.30, 0.82, 1.0],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Center(
                    child: t == null
                        ? const SizedBox.shrink()
                        : CoverArt(trackId: t.id, localPath: t.coverPath),
                  ),
                ),
              ),
              if (t != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                  child: Column(
                    children: [
                      Text(t.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 22,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(t.artist,
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              IconButton(
                iconSize: 72,
                color: Afisha.lime,
                icon: const Icon(Icons.play_circle_filled),
                onPressed: _start,
              ),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ],
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

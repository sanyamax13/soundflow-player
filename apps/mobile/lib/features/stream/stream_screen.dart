import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/config.dart';
import '../../core/cover_thumb.dart';
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
  // Какая-то одна песня "на витрине" стартового экрана — просьба Alex
  // 05.09.2026: вместо голого значка play сразу видно, что вот-вот
  // заиграет. Выбирается один раз при загрузке экрана, не на каждую
  // перерисовку — иначе картинка бы дёргалась.
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
  }

  /// Тап по кнопке «начать» — раньше заводили вперемешку сами при открытии
  /// вкладки, Alex попросил убрать (05.09.2026): не играть само при запуске.
  void _start() {
    final items = _items;
    if (items == null || items.isEmpty) return;
    final queue = [
      for (final t in items)
        NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ];
    // Не ждём: экран (PlayerView) сам покажет обложку и название, как
    // только реально заиграет.
    AppScope.of(context).player.playQueue(queue, shuffle: true).catchError((_) {});
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
              : PlayerView(emptyState: _startView(items.length)),
    );
  }

  Widget _startView(int count) {
    final t = _preview;
    return Center(
      child: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t != null) ...[
              CoverThumb(path: t.coverPath, url: coverUrlFor(t.id), size: 220, radius: 16),
              const SizedBox(height: 16),
              Text(t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Afisha.ink, fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(t.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Afisha.inkDim)),
              const SizedBox(height: 20),
            ],
            IconButton(
              iconSize: 72,
              color: Afisha.lime,
              icon: const Icon(Icons.play_circle_filled),
              onPressed: _start,
            ),
            const SizedBox(height: 12),
            Text('Слушать вперемешку — $count песен',
                style: const TextStyle(color: Afisha.inkDim)),
          ],
        ),
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

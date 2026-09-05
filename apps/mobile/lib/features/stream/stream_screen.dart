import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/cover_backdrop.dart';
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
    // Заводим именно ту песню, что показана на заставке, дальше — вперемешку.
    // Без этого play запускал случайную из вперемешку, а не показанную
    // (Alex 06.09.2026: «нажимаю — играет другая песня»).
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
              : PlayerView(emptyState: _startView(items.length)),
    );
  }

  // Во весь экран, как настоящий плеер (PlayerView) — просьба Alex
  // 05.09.2026: "почему не во весь экран?" после первой версии с маленькой
  // карточкой посередине. Так до и после нажатия play экран выглядит
  // одинаково, без скачка.
  Widget _startView(int count) {
    final t = _preview;
    final placeholder = Container(
      color: Afisha.surfaceHi,
      child: const Center(child: Icon(Icons.graphic_eq, color: Afisha.lime, size: 96)),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // Та же обложка, что в плеере: целая по центру + размытая копия
        // фоном (вариант «с размытым фоном», Alex 05.09.2026).
        t == null
            ? placeholder
            : CoverBackdrop(trackId: t.id, localPath: t.coverPath),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black.withValues(alpha: 0.7),
              ],
              stops: const [0.30, 0.82, 1.0],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Обложка занимает всё место сверху; название идёт строго под
              // ней и не наезжает на картинку (Alex 06.09.2026).
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
                              fontSize: 22, color: Colors.white, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(t.artist, style: const TextStyle(color: Colors.white70)),
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
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text('Слушать вперемешку — $count песен',
                    style: const TextStyle(color: Colors.white70)),
              ),
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

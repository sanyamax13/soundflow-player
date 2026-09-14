import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../library/library_screen.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Открыл вкладку — сразу
/// полноэкранный плеер: обложка, название, полоска-волна и кнопки
/// ⏮ ▶ ⏭ — но на паузе. Музыка НЕ заводится сама (Alex 06.09.2026: «зачем её
/// запускать?»), играть начинает по нажатию play. Порядок песен —
/// вперемешку, переключается иконкой в самом плеере.
class StreamScreen extends ConsumerStatefulWidget {
  const StreamScreen({super.key});

  @override
  ConsumerState<StreamScreen> createState() => _StreamScreenState();
}

/// Скрытые исполнители — вон из Потока (Опус-ревью телефона 14.09.2026,
/// пункт 6). Отдельная функция — проверяется без сборки экрана/плеера.
@visibleForTesting
List<DownloadedTrack> excludeHidden(List<DownloadedTrack> all, Set<String> hidden) =>
    [for (final t in all) if (!hidden.contains(t.artist)) t];

class _StreamScreenState extends ConsumerState<StreamScreen> {
  List<DownloadedTrack>? _items;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final hidden = await db.hiddenArtists();
    final all = await ref.read(downloadsProvider).list();
    // Скрытые исполнители (долгое нажатие → «скрыть исполнителя») реально
    // пропадают из Потока, а не просто продолжают играть с обещанием на
    // словах (Опус-ревью телефона 14.09.2026, пункт 6).
    final items = excludeHidden(all, hidden);
    if (!mounted) return;
    setState(() => _items = items);
    if (items.isEmpty) return;

    final player = ref.read(playerProvider);
    // Раньше очередь строилась только один раз за всё время работы
    // приложения (player.now.value == null — становится не-null сразу же
    // после первой зарядки очереди и остаётся таким навсегда) — новые
    // скачанные песни не попадали в Поток без полного перезапуска
    // приложения (пункт 4). Теперь сверяем количество: не менялось — вкладку
    // просто открыли заново, трогать нечего; выросло — либо первая зарядка
    // (плеер пуст), либо дозапись новых треков в хвост без остановки того,
    // что уже играет.
    if (player.streamQueueCount == items.length) return;
    final queue = [
      for (final t in items)
        NowPlaying(
            id: t.id,
            title: t.title,
            artist: t.artist,
            path: t.path,
            coverPath: t.coverPath),
    ];
    if (player.now.value == null) {
      unawaited(player.playQueue(
        queue,
        startIndex: Random().nextInt(items.length),
        shuffle: true,
        autoplay: false,
      ));
    } else {
      unawaited(player.appendNewToQueue(queue));
    }
    player.streamQueueCount = items.length;
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
                'Скачай музыку — Поток играет уже скачанное без интернета.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Afisha.inkDim),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LibraryScreen()),
                ),
                child: const Text('Скачать музыку'),
              ),
            ],
          ),
        ),
      );
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/local_taste.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../library/library_screen.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';

/// Поток — простое офлайн-радио по скачанной музыке. Открыл вкладку — сразу
/// полноэкранный плеер: обложка, название, полоска-волна и кнопки
/// ⏮ ▶ ⏭ — но на паузе. Музыка НЕ заводится сама (Alex 06.09.2026: «зачем её
/// запускать?»), играть начинает по нажатию play. Порядок песен — под вкус
/// (`weightedShuffleByTaste`, доделано 14.09.2026 по слову Alex — раньше
/// была просто перетасовка), переключается иконкой в самом плеере.
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

/// Порядок «Потока» под вкус — читает векторы уже скачанных треков и
/// сохранённые центры вкуса (`taste_centroids`, тот же kv, что офлайн-радио)
/// прямо с телефона, без сети. Векторов/центров ещё нет — вернёт `items`,
/// просто перетасованный (`weightedShuffleByTaste` вырождается в обычную
/// перетасовку при равных весах, отдельный путь не нужен).
@visibleForTesting
Future<List<DownloadedTrack>> orderByTaste(Db db, List<DownloadedTrack> items) async {
  final rawVecs = await db.trackVectorsFor([for (final t in items) t.id]);
  final vecs = <String, Float32List>{};
  for (final e in rawVecs.entries) {
    final v = bytesToVec(e.value);
    if (v != null) vecs[e.key] = v;
  }
  final (longTerm, recent) = decodeCentroids(await db.kvGet('taste_centroids'));
  final orderedIds = weightedShuffleByTaste(
    ids: [for (final t in items) t.id],
    vecs: vecs,
    artists: {for (final t in items) t.id: t.artist},
    centroidsLongTerm: longTerm,
    centroidsRecent: recent,
  );
  final byId = {for (final t in items) t.id: t};
  return [for (final id in orderedIds) if (byId[id] case final t?) t];
}

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
    // Порядок — под вкус, не просто вперемешку (Alex TG 14.09.2026: «доделай»
    // урезанный пункт 6 — раньше учитывались только скрытые исполнители).
    // Нет ещё вкуса/отпечатков — orderByTaste сама выродится в обычную
    // перетасовку, отдельного «если вкуса нет» пути тут не нужно.
    final ordered = await orderByTaste(db, items);
    final queue = [
      for (final t in ordered)
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
        startIndex: 0,
        shuffle: false,
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

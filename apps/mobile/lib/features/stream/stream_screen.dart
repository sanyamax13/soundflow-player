import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/solar.dart';

import '../../app/providers.dart';
import '../../core/app_log.dart';
import '../../core/local_taste.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
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
  final (longTerm, recent) = decodeCentroids(await db.kvGet('taste_centroids'));
  // «Забытое»: не играли полгода или ни разу — примерно каждая 8-я песня (local_taste.dart).
  // Пока истории мало (всё «ни разу») — mixForgotten ничего не меняет.
  final forgotten = await db.forgottenIds(DateTime.now().subtract(const Duration(days: 180)));
  // Счёт — в отдельном изоляте (`offlineComputeRunner`, как у офлайн-радио): чёрный ящик
  // 27.09.2026 — при каждом запуске экран замирал на ~0,5 с, пока 11 700 отпечатков
  // сравнивались с центрами вкуса прямо на UI-потоке. Тесты подменяют раннер синхронным.
  final orderedIds = await offlineComputeRunner(_orderJob(
    ids: [for (final t in items) t.id],
    blobs: rawVecs,
    artists: {for (final t in items) t.id: t.artist},
    longTerm: longTerm,
    recent: recent,
    forgotten: forgotten,
  ));
  final byId = {for (final t in items) t.id: t};
  return [for (final id in orderedIds) if (byId[id] case final t?) t];
}

/// Отдельной функцией, чтобы замыкание для изолята захватывало только эти данные
/// (а не базу/экран — их в другой изолят не передать).
List<String> Function() _orderJob({
  required List<String> ids,
  required Map<String, Uint8List> blobs,
  required Map<String, String> artists,
  required List<Float32List> longTerm,
  required List<Float32List> recent,
  required Set<String> forgotten,
}) =>
    () {
      final vecs = <String, Float32List>{};
      for (final e in blobs.entries) {
        final v = bytesToVec(e.value);
        if (v != null) vecs[e.key] = v;
      }
      return weightedShuffleByTaste(
        ids: ids,
        vecs: vecs,
        artists: artists,
        centroidsLongTerm: longTerm,
        centroidsRecent: recent,
        forgotten: forgotten,
      );
    };

class _StreamScreenState extends ConsumerState<StreamScreen> {
  List<DownloadedTrack>? _items;

  /// Очередь Потока ещё заряжается (порядок под вкус + загрузка источника — на
  /// телефоне это секунды). Плеер в это время видит `now == null` и раньше писал
  /// «Ничего не играет» (Alex TG 19950, 19.09.2026: «в начале говорит что нет
  /// песен, через несколько секунд они появляются») — теперь на это время
  /// колесо, а текст остаётся только если очередь так и не собралась.
  bool _building = true;

  /// Кэш сработал: заряжен прошлый список ДО того, как настоящая загрузка из
  /// базы досчиталась. Нужно на случай, когда Android полностью убил процесс
  /// приложения (смахнули из списка последних) — тогда даже переключение
  /// вкладок изнутри (см. `Shell`) не спасает, список грузится с нуля.
  /// Здесь вместо колеса сразу показываем прошлый список, пока настоящий
  /// тихо досчитывается в фоне (Alex TG 24.09.2026).
  bool _primed = false;

  static const _cacheKey = 'stream_cache_queue';
  static const _cacheCap = 60;

  // `_items` остаётся null, пока не отработает первый await внутри `_load()`
  // (теперь их на один больше — приоритет кэшу) — без отдельного флага
  // повторный `didChangeDependencies` в это окно запускал вторую параллельную
  // загрузку (поймано тестами).
  bool _loading = false;

  /// Захвачено в initState (не через ref.read в dispose — Riverpod это не
  /// позволяет после разбора виджета).
  late final PlayerController _player;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null && !_loading) _load();
  }

  @override
  void initState() {
    super.initState();
    // Вкладки больше не пересоздают друг друга (Shell — IndexedStack,
    // 24.09.2026) — «Моя музыка»/избранное могут поставить свою очередь,
    // пока «Поток» просто ждёт в фоне. Раньше чужую очередь ловил каждый
    // новый заход на вкладку (didChangeDependencies), теперь экран этого
    // не видит — слушаем player.now напрямую (Alex TG 24.09.2026, скрин:
    // «нажал Поток — следующей песни нет»).
    //
    // Ссылку на player берём здесь и держим полем — в dispose() нельзя
    // звать ref.read (Riverpod бросает «Cannot use ref after disposed»).
    _player = ref.read(playerProvider);
    _player.now.addListener(_onForeignTakeover);
  }

  @override
  void dispose() {
    _player.now.removeListener(_onForeignTakeover);
    super.dispose();
  }

  void _onForeignTakeover() {
    final items = _items;
    if (items == null || items.isEmpty) return;
    if (_player.now.value == null || _player.streamQueueCount >= 0) return; // не чужая очередь
    unawaited(_fillQueue(ref.read(dbProvider), items));
  }

  /// Только на действительно холодном старте (плеер ещё совсем пустой) —
  /// если что-то уже играет (например, за это время открыли «Мою музыку» и
  /// нажали play), кэш ничего не трогает.
  Future<void> _primeFromCache(Db db, PlayerController player) async {
    if (player.now.value != null || player.streamQueueCount != -1) return;
    final raw = await db.kvGet(_cacheKey);
    // Где остановились в прошлый раз (PlayerController.onResumePoint) — эта песня первой и с
    // того же места: система закрыла приложение на паузе — открыл, а там то же, что было
    // (чёрный ящик 27.09.2026: Samsung «заморозил» плеер, после открытия — новая очередь).
    Map<String, dynamic>? resume;
    try {
      resume = jsonDecode(await db.kvGet('resume_point') ?? '') as Map<String, dynamic>;
    } catch (_) {}
    if (!mounted) return;
    List<dynamic> decoded = const [];
    try {
      if (raw != null && raw.isNotEmpty) decoded = jsonDecode(raw) as List<dynamic>;
    } catch (_) {}
    if (resume != null) decoded = [resume, ...decoded.where((e) => e is Map && e['id'] != resume!['id'])];
    if (decoded.isEmpty) return;
    // Кэш очереди мог устареть: песню с тех пор убрали с телефона. Без этой
    // проверки она всплывала первой при запуске и не играла (0:00 / 0:00) —
    // Alex, голосовое TG 26.09.2026, v110. Файл на месте — берём.
    final queue = [
      for (final e in decoded)
        if (e is Map<String, dynamic> && File(e['path'] as String).existsSync())
          NowPlaying(
            id: e['id'] as String,
            title: e['title'] as String,
            artist: e['artist'] as String,
            path: e['path'] as String,
            coverPath: e['cover'] as String?,
          ),
    ];
    if (queue.isEmpty || !mounted) return;
    final resumed = resume != null && queue.first.id == resume['id'];
    final pos = resumed ? Duration(milliseconds: (resume['pos_ms'] as num?)?.toInt() ?? 0) : Duration.zero;
    await player.playQueue(queue, startIndex: 0, shuffle: false, autoplay: false, initialPosition: pos);
    if (mounted) setState(() => _primed = true);
  }

  Future<void> _load() async {
    _loading = true;
    final db = ref.read(dbProvider);
    await _primeFromCache(db, ref.read(playerProvider));
    final hidden = await db.hiddenArtists();
    final all = await ref.read(downloadsProvider).list();
    // Скрытые исполнители (долгое нажатие → «скрыть исполнителя») реально
    // пропадают из Потока, а не просто продолжают играть с обещанием на
    // словах (Опус-ревью телефона 14.09.2026, пункт 6).
    final items = excludeHidden(all, hidden);
    if (!mounted) return;
    setState(() => _items = items);
    if (items.isEmpty) return;
    try {
      await _fillQueue(db, items);
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  // Гейт от повторного входа: сам _fillQueue меняет player.now (playQueue/
  // takeOverWithStream/appendNewToQueue), а на это реагирует _onForeignTakeover
  // выше — без гейта он тут же попытался бы запустить ещё один _fillQueue
  // поверх уже идущего.
  bool _reconciling = false;

  Future<void> _fillQueue(Db db, List<DownloadedTrack> items) async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      await _fillQueueInner(db, items);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _fillQueueInner(Db db, List<DownloadedTrack> items) async {
    final player = ref.read(playerProvider);
    // Раньше очередь строилась только один раз за всё время работы
    // приложения (player.now.value == null — становится не-null сразу же
    // после первой зарядки очереди и остаётся таким навсегда) — новые
    // скачанные песни не попадали в Поток без полного перезапуска
    // приложения (пункт 4). Теперь сверяем количество: не менялось — вкладку
    // просто открыли заново, трогать нечего; выросло — либо первая зарядка
    // (плеер пуст), либо дозапись новых треков в хвост без остановки того,
    // что уже играет.
    // Очередь могла стать чужой: в «Моей музыке» нажали «играть» по избранному /
    // папке / найденному — `playQueue` тогда сбрасывает счётчик в -1, а что-то
    // играет (now != null). Раньше счётчик оставался «как у Потока» и Поток
    // продолжал играть избранное (Alex TG 20135, 20.09.2026). Песня, что играет
    // сейчас, доигрывает, дальше — Поток (`takeOverWithStream`).
    final foreign = player.now.value != null && player.streamQueueCount < 0;
    if (!foreign && player.streamQueueCount == items.length) return;
    final sw = Stopwatch()..start();
    // Порядок — под вкус, не просто вперемешку (Alex TG 14.09.2026: «доделай»
    // урезанный пункт 6 — раньше учитывались только скрытые исполнители).
    // Нет ещё вкуса/отпечатков — orderByTaste сама выродится в обычную
    // перетасовку, отдельного «если вкуса нет» пути тут не нужно.
    final ordered = await orderByTaste(db, items);
    final orderMs = sw.elapsedMilliseconds;
    // Сохраняем для следующего холодного старта (см. _primeFromCache) —
    // не ждём, пишем в фоне.
    unawaited(db.kvSet(
      _cacheKey,
      jsonEncode([
        for (final t in ordered.take(_cacheCap))
          {'id': t.id, 'title': t.title, 'artist': t.artist, 'path': t.path, 'cover': t.coverPath},
      ]),
    ));
    final queue = [
      for (final t in ordered)
        NowPlaying(
            id: t.id,
            title: t.title,
            artist: t.artist,
            path: t.path,
            coverPath: t.coverPath),
    ];
    final started = player.now.value == null
        ? player.playQueue(
            queue,
            startIndex: 0,
            shuffle: false,
            autoplay: false,
          )
        : foreign
            ? player.takeOverWithStream(queue)
            : player.appendNewToQueue(queue);
    // Счётчик — сразу, не дожидаясь конца зарядки (как и раньше): повторное
    // открытие вкладки за это время не соберёт очередь второй раз.
    player.streamQueueCount = items.length;
    await started;
    // Сколько заняла зарядка на телефоне — смотреть в «Журнале» (Настройки), чтобы
    // видеть, что именно долгое: порядок под вкус или загрузка источника.
    unawaited(AppLog.event('stream_queue_ready', {
      'tracks': items.length,
      'order_ms': orderMs,
      'total_ms': sw.elapsedMilliseconds,
    }));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final ready = items != null || _primed;
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : (items != null && items.isEmpty)
              ? _empty()
              : PlayerView(
                  emptyState: (_building && !_primed)
                      ? const Center(child: CircularProgressIndicator())
                      : null,
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(SolarBold.soundwave, color: Afisha.inkDim, size: 64),
              const SizedBox(height: 16),
              const Text('В Потоке пока пусто',
                  style: TextStyle(fontSize: 18, color: Afisha.ink)),
              const SizedBox(height: 8),
              const Text(
                'Поток играет то, что уже на телефоне, без интернета. '
                'Песни для телефона отмечаются в программе на компьютере.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Afisha.inkDim),
              ),
            ],
          ),
        ),
      );
}

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../core/app_log.dart';
import '../../core/config.dart';
import '../../core/local_taste.dart';
import '../../core/notice.dart';
import '../../core/removal_reasons.dart';
import '../../data/db.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import 'cover_art.dart';
import 'cover_palette.dart';
import 'dot_matrix_seek.dart';
import 'player_controller.dart';

/// Полноэкранный плеер — вариант 4.2 «Радио-объект» (Alex TG 18568–18590,
/// с разбором внешнего дизайнера). Управление в первую очередь жестами по
/// обложке, снизу — маленький ряд кнопок как подсказка/подстраховка.
///
/// Жесты по обложке:
///  • тап — пауза/играть (мгновенно — раньше делил жест с двойным тапом
///    «нравится» и ждал ~300 мс, пока Flutter поймёт, один тап или два;
///    сердечко теперь только кнопкой в ряду ниже, Опус-ревью телефона
///    14.09.2026, пункт 10);
///  • смахнуть влево/вправо — следующая/предыдущая (обложка едет за пальцем);
///  • смахнуть вверх — очередь «Дальше»;
///  • смахнуть вниз — свернуть плеер (если открыт поверх).
/// Меню долгого нажатия убрано целиком (Alex TG 19.09.2026: «оно не нужно,
/// если есть кнопка радио»). Вместе с ним ушли «скрыть исполнителя», «больше
/// такого», «почему играет» — других мест в приложении для них не было;
/// «меньше такого» остался в «Моей музыке». Радио и «убрать совсем» — только
/// кнопками (таблетка сверху, урна внизу). План упрощения, п.1-2 и 6.
/// Точечная матрица с цифрами внизу — перемотка (тап или вести пальцем по
/// точкам), см. [DotMatrixSeek]; вариант 19, Alex TG 19.09.2026 (раньше была
/// волна из 64 столбиков с сервера).
/// «?» вверху — та же инструкция внутри приложения; в первый раз
/// показывается сама.
///
/// Общий виджет для двух мест:
///  • вкладка «Поток» вставляет его в тело, без кнопки «вниз»;
///  • [NowPlayingScreen] открывает поверх (тап по мини-плееру), с «вниз».
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key, this.onDismiss, this.emptyState});

  final VoidCallback? onDismiss;
  final Widget? emptyState;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView>
    with TickerProviderStateMixin {
  bool _wired = false;
  PlayerController? _controller;
  PlayerController get _p => _controller!;

  String? _favTrackId;
  bool _fav = false;

  final ValueNotifier<CoverColors> _tint =
      ValueNotifier(CoverColors.fallback);

  // Куда «прилетает» сердечко при лайке — центр кнопки лайка в _transport(),
  // а не центр экрана (Опус-ревью «Поток» 23.09.2026, пункт 3: место нажатия
  // и место анимации не совпадали).
  final LayerLink _favLink = LayerLink();

  // Медленный перелив фона под цвет обложки (Alex TG 18608). Обложка не
  // трогается — она якорь.
  late final AnimationController _bg;
  late final AnimationController _heart;
  late final AnimationController _dragX;
  // Плашка «Дальше» тянется за пальцем (Alex TG 24.09.2026: «аккуратно за
  // моим пальцем она шла бы, сейчас просто по свайпу поднимается сразу
  // вся») — 0 = свёрнута (только строка «Дальше: …»), 1 = раскрыта на
  // весь список. Значение двигается ЖИВЬЁМ во время onVerticalDragUpdate,
  // а не только по итоговой скорости жеста.
  late final AnimationController _queueOpen;
  static const double _queuePeek = 78;

  bool _showHelp = false;

  @override
  void initState() {
    super.initState();
    _bg = AnimationController(
      // 45 с, не 15 — за получас слушания фон не должен тикать заметным
      // ритмом рядом с точками перемотки (Опус-ревью «Поток» 23.09.2026,
      // пункт 6: несколько несвязанных движений в такт друг другу не идут).
      vsync: this,
      duration: const Duration(seconds: 45),
    );
    _heart = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _dragX = AnimationController.unbounded(vsync: this, value: 0);
    _queueOpen = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  void _animateQueueTo(double target) {
    _queueOpen.animateTo(target, curve: Curves.easeOutCubic);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wired) {
      _wired = true;
      _controller = ref.read(playerProvider);
      _p.now.addListener(_onNow);
      _onNow();
      _maybeShowHelpFirstRun();
    }
  }

  @override
  void dispose() {
    _controller?.now.removeListener(_onNow);
    _bg.dispose();
    _heart.dispose();
    _dragX.dispose();
    _queueOpen.dispose();
    _tint.dispose();
    super.dispose();
  }

  // ── обложка сменилась: избранное + цвета перелива фона ─────────────────
  void _onNow() {
    // Перелив фона крутим, только когда есть трек (батарея + чтобы тесты с
    // pumpAndSettle не висели на бесконечной анимации).
    if (_p.now.value != null) {
      if (!_bg.isAnimating) _bg.repeat();
    } else {
      _bg.stop();
    }
    _syncFav();
    _syncTint();
    if (mounted) setState(() {}); // название
  }

  Future<void> _syncFav() async {
    final cur = _p.now.value;
    if (cur == null || cur.id == _favTrackId) return;
    final v = await ref.read(downloadsProvider).favorite(cur.id);
    if (!mounted) return;
    setState(() {
      _favTrackId = cur.id;
      _fav = v;
    });
  }

  Future<void> _syncTint() async {
    final cur = _p.now.value;
    if (cur == null) return;
    final img = coverImageProvider(cur.id, cur.coverPath);
    final immediate = CoverPalette.cached(img);
    if (immediate != null) {
      _tint.value = immediate;
      return;
    }
    final c = await CoverPalette.of(img);
    if (mounted && _p.now.value?.id == cur.id) _tint.value = c;
  }

  // ── первый запуск: показать инструкцию один раз ────────────────────────
  Future<void> _maybeShowHelpFirstRun() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final marker = File('${dir.path}/player_help_seen');
      if (marker.existsSync()) return;
      marker.writeAsStringSync('1');
      if (mounted) setState(() => _showHelp = true);
    } catch (_) {
      // не смогли записать метку — просто не показываем авто-подсказку
    }
  }

  // ── действия ──────────────────────────────────────────────────────────
  Future<void> _toggle() => _p.toggle();

  Future<void> _toggleFavButton() async {
    final cur = _p.now.value;
    if (cur == null) return;
    final v = !_fav;
    setState(() => _fav = v);
    await ref.read(downloadsProvider).setFavorite(cur.id, v);
    if (v) _heart.forward(from: 0);
  }

  // «Дальше» / «Назад» плашкой не подписываем: смену песни и так видно по
  // обложке и названию, а плашка на каждый свайп только мельтешила.
  void _swipeNext() => _p.next();

  void _swipePrev() => _p.prev();

  /// Спросить причину (список общий с «Моей музыкой», core/removal_reasons.dart)
  /// и убрать трек с телефона (и с сервера — обычным синком). Раньше рядом
  /// была ещё «не хочу эту версию» — она удаляла файл СРАЗУ, без вопроса о
  /// причине вообще; теперь это просто один из трёх пунктов того же листа
  /// (Опус-ревью телефона 14.09.2026, пункт 9 — было пять пересекающихся
  /// действий «не нравится», осталось два: «меньше такого» и «убрать совсем»).
  Future<void> _confirmDelete(NowPlaying now) async {
    final reason = await pickRemovalReason(context);
    if (reason == null || !mounted) return;
    await ref.read(downloadsProvider).delete(now.id, reason: reason);
    if (!mounted) return;
    await _p.next();
    Notice.show('Убрал с телефона',
        subtitle: '${now.artist} — ${now.title}', kind: NoticeKind.removed);
  }

  /// Радио «по этой песне». Всё считает ТЕЛЕФОН по уже лежащим на нём
  /// звуковым отпечаткам, сервер на нажатие не спрашиваем (Alex TG
  /// 19.09.2026: «сервер изначально всё делает и отдаёт на телефон, а
  /// телефон уже сам»). Журнал 18.09 показал причину задержки: из ~8,2 с
  /// около 8 уходило на ожидание недоступного сервера (`connectTimeout`), а
  /// сам подбор из скачанного — 0,004 с на первые 80 песен и 0,1 с на
  /// остальные 416.
  ///
  /// Нет отпечатка у самой песни — подтягиваем только его ([_fetchSeedVector],
  /// не дольше [_seedVectorWait]) и считаем локально. Не вышло — говорим как
  /// есть и просим докачать отпечатки в фоне (это дыра в доставке, её
  /// видно в журнале по `vectors_backfill`).
  Future<void> _radio(NowPlaying now) async {
    if (_p.radio.value) {
      await _p.stopRadio();
      Notice.show('Радио выключил');
      return;
    }
    final hidden = await ref.read(dbProvider).hiddenArtists();
    final all = (await ref.read(downloadsProvider).list())
        .where((t) => !hidden.contains(t.artist))
        .toList();
    if (all.length < 2) return;
    // Реальное время НА ЭТОМ ТЕЛЕФОНЕ от нажатия до результата — Alex TG
    // 14.09.2026 отдельно поправил, что замеры на компьютере (SSD/память
    // сильно быстрее) не показывают его реальную задержку: «должен как-то
    // на моём телефоне... а не с компьютера». AppLog.event пишет
    // DateTime.now() на телефоне пользователя, не на деве.
    final sw = Stopwatch()..start();
    try {
      if (!mounted) return;
      var tail = await _offlineRadioFallback(now, all, sw);
      if (tail == null && await _fetchSeedVector(now.id)) {
        if (!mounted) return;
        tail = await _offlineRadioFallback(now, all, sw);
      }
      if (!mounted) return;
      if (tail == null) {
        unawaited(AppLog.event('radio_no_fingerprint', {'elapsed_ms': sw.elapsedMilliseconds}));
        Notice.show('Похожее не подобрать',
            subtitle: 'У этой песни нет звукового отпечатка на телефоне',
            kind: NoticeKind.warn);
        unawaited(ref.read(downloadsProvider).backfillVectors());
        return;
      }
      unawaited(AppLog.event('radio_local_ok', {
        'elapsed_ms': sw.elapsedMilliseconds,
        'picked': tail.length,
      }));
      await _p.setSimilarTail(tail);
      Notice.show('Дальше — похожее по звуку');
      unawaited(_offlineRadioTopUp(sw));
    } catch (_) {
      unawaited(AppLog.event('radio_error', {'elapsed_ms': sw.elapsedMilliseconds}));
      Notice.show('Радио не собралось', kind: NoticeKind.warn);
    }
  }

  /// Сколько ждём у сервера отпечаток ОДНОЙ песни, когда его нет на телефоне.
  static const _seedVectorWait = Duration(seconds: 2);

  /// Подтянуть у сервера отпечаток одной песни (несколько сотен байт) и
  /// положить на телефон. true — теперь он лежит локально. Сервер молчит или
  /// не знает песню — false; дольше [_seedVectorWait] не ждём.
  Future<bool> _fetchSeedVector(String id) async {
    final api = ref.read(apiProvider);
    final db = ref.read(dbProvider);
    try {
      final got = await api.trackVectors([id]).timeout(_seedVectorWait);
      final bytes = got[id];
      if (bytes == null) return false;
      await db.setTrackVector(id, bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Подбор радио на телефоне: сравнивает уже скачанные треки по лежащим на
  /// нём отпечаткам (docs/superpowers/specs/2026-09-13-taste-layers-offline-
  /// design.md §4.5-4.6). С 19.09.2026 это ОСНОВНОЙ путь радио, а не фолбэк
  /// на случай недоступного сервера (имена `_offline*` и события
  /// `radio_offline_*` в журнале — с тех времён, оставлены). Нет отпечатка у
  /// seed — null (вызывающий тогда пробует подтянуть его у сервера, см.
  /// [_fetchSeedVector]). Возвращает только БЫСТРЫЙ первый кусок — дальше
  /// [_offlineRadioTopUp] сам дозагружает остальное в фоне (см. его
  /// комментарий).
  Future<List<NowPlaying>?> _offlineRadioFallback(
      NowPlaying now, List<DownloadedTrack> all, Stopwatch sw) async {
    final db = ref.read(dbProvider);
    final seedBytes = await db.trackVector(now.id);
    final seedVec = seedBytes == null ? null : bytesToVec(seedBytes);
    if (seedVec == null) return null;

    final allOthers = [for (final t in all) if (t.id != now.id) t]..shuffle();
    // Кусками, а не всё за один поход в базу — Alex TG 14.09.2026: «подбирать
    // кусочками, типа 10-15 песен, прослушал — дочитывает ещё». Журнал
    // (elapsed_ms) на реальном телефоне показал: сам расчёт — единицы
    // миллисекунд, а вот чтение 500 отпечатков из базы телефона — больше 8
    // секунд молчания. Читаем сразу маленький кусок для быстрого старта,
    // остальное — вторым походом в фоне, пока первый уже играет
    // ([_offlineRadioTopUp]).
    const firstBatch = 80;
    const maxOfflineCandidates = 500;
    final capped = allOthers.length > maxOfflineCandidates
        ? allOthers.sublist(0, maxOfflineCandidates)
        : allOthers;
    final first = capped.length > firstBatch ? capped.sublist(0, firstBatch) : capped;
    _offlineRadioRest = capped.length > firstBatch ? capped.sublist(firstBatch) : const [];

    final centroidsJson = await db.kvGet('taste_centroids');
    _offlineRadioCentroids = centroidsJson;
    _offlineRadioSeedVec = seedVec;
    return _offlineRank(db, seedVec, first, centroidsJson, sw, phase: 'first');
  }

  // Состояние между первым и вторым (фоновым) куском офлайн-радио — живёт
  // только на время одного нажатия «радио», перечитывается в
  // _offlineRadioTopUp сразу после того, как первый кусок уже показан.
  List<DownloadedTrack> _offlineRadioRest = const [];
  String? _offlineRadioCentroids;
  Float32List? _offlineRadioSeedVec;

  /// Общий расчёт для одного куска кандидатов (используется и первым, и
  /// вторым походом) — читает отпечатки, считает похожесть в изоляте.
  Future<List<NowPlaying>?> _offlineRank(Db db, Float32List seedVec,
      List<DownloadedTrack> candidates, String? centroidsJson, Stopwatch sw,
      {required String phase}) async {
    if (candidates.isEmpty) return null;
    final rawVecs = await db.trackVectorsFor([for (final t in candidates) t.id]);
    unawaited(AppLog.event('radio_offline_fetch_$phase', {
      'elapsed_ms': sw.elapsedMilliseconds,
      'candidates': candidates.length,
      'vectors': rawVecs.length,
    }));
    if (rawVecs.length < 2) return null;

    final (longTerm, recent) = decodeCentroids(centroidsJson);
    final byId = {for (final t in candidates) t.id: t};
    final candidateArtists = {for (final t in candidates) t.id: t.artist};
    // Косинус к seed и к каждому центру вкуса на каждого кандидата — тяжёлый
    // счёт, синхронный сам по себе. Раньше выполнялся прямо тут, на UI-
    // изоляте — интерфейс замирал, кнопка «не отвечала», звук заикался
    // (Alex TG 14.09.2026: «тормозит... кнопка радио отмирает» — оказалось,
    // дело не в сервере, он был не дома, а именно в этом расчёте). Спека
    // это и требовала с самого начала (§4.6: «в изоляте, не на UI-потоке»)
    // — здесь этого не было. `offlineComputeRunner` — по умолчанию
    // `Isolate.run` (копирует Uint8List/Map в отдельный изолят, считает
    // там, интерфейс не блокирует); тесты подменяют его синхронным вызовом
    // (см. local_taste.dart). Разбор BLOB→вектор — тоже ВНУТРИ изолята
    // (`orderOfflineFromBlobs`, не `orderOffline` напрямую): сам разбор
    // BLOB'ов не легче ранжирования, а раньше оставался снаружи.
    final orderedIds = await offlineComputeRunner(() => orderOfflineFromBlobs(
          seedVec: seedVec,
          candidateBlobs: rawVecs,
          candidateArtists: candidateArtists,
          centroidsLongTerm: longTerm,
          centroidsRecent: recent,
        ));
    unawaited(AppLog.event('radio_offline_compute_$phase', {
      'elapsed_ms': sw.elapsedMilliseconds,
      'ordered': orderedIds.length,
    }));
    if (orderedIds.isEmpty) return null;
    return [
      for (final id in orderedIds)
        if (byId[id] case final t?)
          NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ];
  }

  /// Вторая, фоновая порция офлайн-радио — досчитывает остаток кандидатов
  /// (см. `_offlineRadioRest`, оставлен `_offlineRadioFallback`) и дозаписывает
  /// в уже играющую очередь через `PlayerController.extendSimilarTail`. Не
  /// await-ится вызывающим кодом — начинает работу молча, пока играет первый
  /// кусок, ничего не блокирует.
  Future<void> _offlineRadioTopUp(Stopwatch sw) async {
    final rest = _offlineRadioRest;
    final seedVec = _offlineRadioSeedVec;
    if (rest.isEmpty || seedVec == null || !mounted) return;
    final db = ref.read(dbProvider);
    final more = await _offlineRank(db, seedVec, rest, _offlineRadioCentroids, sw, phase: 'more');
    if (more == null || more.isEmpty || !mounted) return;
    await _p.extendSimilarTail(more);
    unawaited(AppLog.event('radio_offline_topup_done', {
      'elapsed_ms': sw.elapsedMilliseconds,
      'added': more.length,
    }));
  }

  // ── сборка ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: _p.now,
      builder: (context, now, _) {
        if (now == null) {
          return widget.emptyState ??
              const Center(
                child: Text('Ничего не играет',
                    style: TextStyle(color: Afisha.inkDim)),
              );
        }
        final img = coverImageProvider(now.id, now.coverPath);
        return ValueListenableBuilder<CoverColors>(
          valueListenable: _tint,
          builder: (context, colors, _) => Stack(
            key: ValueKey(now.id),
            fit: StackFit.expand,
            children: [
              // Свой слой: фон перерисовывается каждый кадр (медленный перелив), и без
              // границы вместе с ним каждый кадр заново рисовался весь экран плеера —
              // обложка, тексты, кнопки (оптимизация 21.09.2026, Alex TG 20331).
              RepaintBoundary(child: _LivingBackdrop(anim: _bg, colors: colors, img: img)),
              SafeArea(
                child: Column(
                  children: [
                    _topBar(now),
                    const Spacer(),
                    _coverArea(now, img, colors),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(now.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              // Было 23 — мельче цифр времени под ним (32).
                              // Название важнее «сколько прошло» (Опус-ревью
                              // «Поток» 23.09.2026, пункт 2).
                              fontSize: 26,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(height: 4),
                    Text(now.artist,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 13)),
                    const SizedBox(height: 20),
                    // Полоса обновляется несколько раз в секунду (позиция) — свой слой,
                    // чтобы не тянуть за собой перерисовку остального экрана.
                    RepaintBoundary(
                      child: DotMatrixSeek(
                          controller: _p,
                          tint: colors.isFallback ? Afisha.lime : colors.glow),
                    ),
                    const SizedBox(height: 12),
                    _transport(),
                    const SizedBox(height: 16),
                    const SizedBox(height: _queuePeek),
                  ],
                ),
              ),
              _queueSheet(now),
              _heartPop(),
              if (_showHelp) _HelpOverlay(onClose: () => setState(() => _showHelp = false)),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar(NowPlaying now) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(
          children: [
            if (widget.onDismiss != null)
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(CupertinoIcons.chevron_down, color: Colors.white, size: 24),
              )
            else
              const SizedBox(width: 12),
            const Spacer(),
            // Мельче и бледнее радио-таблетки — подсказку открывают один раз,
            // радио жмут часто, они не должны выглядеть одинаково важными
            // (Опус-ревью «Поток» 23.09.2026, пункт 5).
            IconButton(
              onPressed: () => setState(() => _showHelp = true),
              icon: Icon(CupertinoIcons.question_circle,
                  color: Colors.white.withValues(alpha: 0.45), size: 18),
            ),
            // Раньше был GestureDetector впритык к тексту — тап-зона выходила
            // мельче, чем сам значок рядом («?»), и Alex не мог понять, вся
            // ли «таблетка» кликабельна (TG 14.09.2026). Material+InkWell —
            // явная зона минимум 44×44 (стандарт доступного размера тапа) +
            // видимый эффект нажатия, чтобы попадание было понятно на глаз.
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => _radio(now),
                borderRadius: BorderRadius.circular(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _p.radio,
                    builder: (_, on, _) => Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Была буква «∞» текстом — единственный текстовый
                          // символ среди иконок на экране (Опус-ревью «Поток»
                          // 23.09.2026, пункт 4). Тот же смысл, настоящая иконка.
                          Icon(CupertinoIcons.infinite,
                              color: on ? Afisha.lime : Colors.white70, size: 16),
                          const SizedBox(width: 6),
                          const Text('радио',
                              style:
                                  TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _coverArea(NowPlaying now, ImageProvider? img, CoverColors colors) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onHorizontalDragUpdate: (d) {
        _dragX.value = (_dragX.value + d.delta.dx).clamp(-150.0, 150.0);
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dragX.value <= -60 || v < -600) {
          _swipeNext();
        } else if (_dragX.value >= 60 || v > 600) {
          _swipePrev();
        }
        _dragX.animateTo(0,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 300) {
          widget.onDismiss?.call();
        } else if (v < -300) {
          _animateQueueTo(1);
        }
      },
      child: AnimatedBuilder(
        animation: _dragX,
        builder: (context, child) => Transform.translate(
          offset: Offset(_dragX.value, 0),
          child: Transform.rotate(angle: _dragX.value / 2600, child: child),
        ),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            // Hero — тот же тег, что у обложки в мини-плеере (mini_player.dart):
            // при переходе снизу обложка «вырастает» с места мини-плеера, а не
            // пропадает/появляется новая (Опус-ревью «Поток» 23.09.2026,
            // пункт 12, «как в Apple Music»). На вкладке «Поток» этот виджет
            // ни с кем не летает — Hero просто ничего не делает, пока рядом
            // нет второго с тем же тегом.
            child: Hero(
              tag: 'player-cover',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Afisha.surfaceHi,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    // Обычная тёмная тень для глубины.
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 40,
                        offset: const Offset(0, 16)),
                    // Цветной ореол цвета обложки поверх чёрного фона внизу
                    // экрана — раньше тут была только чёрная тень, и она
                    // сливалась с чёрным низом фона, наполовину терялась
                    // (Опус-ревью «Поток» 23.09.2026, пункт 9). Цветной свет
                    // на чёрном виден, в отличие от чёрной тени на чёрном.
                    BoxShadow(
                        color: colors.glow.withValues(alpha: 0.30),
                        blurRadius: 60,
                        offset: const Offset(0, 20)),
                  ],
                ),
                child: CoverArt(trackId: now.id, localPath: now.coverPath),
              ),
            ),
          ),
        ),
      );
  }

  Widget _transport() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 34,
            color: Colors.white,
            icon: const Icon(CupertinoIcons.backward_fill),
            onPressed: _p.prev,
          ),
          const SizedBox(width: 14),
          ValueListenableBuilder<bool>(
            valueListenable: _p.playing,
            builder: (_, pl, _) => GestureDetector(
              onTap: _p.toggle,
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Afisha.lime,
                  shape: BoxShape.circle,
                ),
                child: Icon(pl ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                    color: Colors.black, size: 30),
              ),
            ),
          ),
          const SizedBox(width: 14),
          IconButton(
            iconSize: 34,
            color: Colors.white,
            icon: const Icon(CupertinoIcons.forward_fill),
            onPressed: _p.next,
          ),
          const SizedBox(width: 10),
          // Цель для сердечка-анимации (_heartPop) — оно прилетает СЮДА, а не
          // в центр экрана (Опус-ревью «Поток» 23.09.2026, пункт 3).
          CompositedTransformTarget(
            link: _favLink,
            child: IconButton(
              iconSize: 26,
              icon: Icon(_fav ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                  color: _fav ? Afisha.lime : Colors.white70),
              onPressed: _toggleFavButton,
            ),
          ),
          Builder(
            builder: (context) => IconButton(
              iconSize: 24,
              icon: const Icon(CupertinoIcons.trash, color: Colors.white70),
              onPressed: () {
                final now = _p.now.value;
                if (now != null) _confirmDelete(now);
              },
            ),
          ),
        ],
      );

  // Плашка «Дальше» + список очереди в одном раскрывающемся блоке: свёрнута
  // (высота _queuePeek) — просто строка, ведёшь пальцем — тянется живьём
  // (onVerticalDragUpdate двигает _queueOpen на каждый кадр жеста, а не
  // только по итоговой скорости), отпустил — доезжает до 0 или 1 сама.
  Widget _queueSheet(NowPlaying now) {
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    final dragRange = maxHeight - _queuePeek;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: _queueOpen,
          builder: (context, _) {
            final t = _queueOpen.value;
            final height = _queuePeek + dragRange * t;
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: Container(
                width: double.infinity,
                height: height,
                color: Afisha.surface.withValues(alpha: 0.6 + 0.4 * t),
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _animateQueueTo(t > 0.5 ? 0 : 1),
                      onVerticalDragUpdate: (d) {
                        _queueOpen.value =
                            (_queueOpen.value - d.delta.dy / dragRange).clamp(0.0, 1.0);
                      },
                      onVerticalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -300) return _animateQueueTo(1);
                        if (v > 300) return _animateQueueTo(0);
                        _animateQueueTo(_queueOpen.value > 0.5 ? 1 : 0);
                      },
                      child: _queueHandleRow(now),
                    ),
                    if (t > 0.01)
                      Expanded(
                        child: Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: IgnorePointer(
                            ignoring: t < 0.6,
                            child: _queueBody(now),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _queueHandleRow(NowPlaying now) {
    final q = _p.queueView;
    final i = _p.currentIndex;
    final nextTitle = (i >= 0 && i + 1 < q.length)
        ? '${q[i + 1].title} — ${q[i + 1].artist}'
        : 'больше ничего';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          Container(
            width: 34,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(CupertinoIcons.list_bullet, color: Colors.white54, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Дальше: $nextTitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13.5)),
              ),
              const Icon(CupertinoIcons.chevron_up, color: Colors.white54, size: 18),
            ],
          ),
        ],
      ),
    );
  }

  Widget _queueBody(NowPlaying now) {
    return StatefulBuilder(
      builder: (context, setBodyState) {
        final q = _p.queueView;
        final i = _p.currentIndex;
        final upcoming = <MapEntry<int, NowPlaying>>[
          for (var k = 0; k < q.length; k++)
            if (k > i) MapEntry(k, q[k]),
        ];
        if (upcoming.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Очередь пустая', style: TextStyle(color: Afisha.inkDim)),
          );
        }
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: upcoming.length,
          onReorderItem: (oldLocal, newLocal) {
            final oldReal = upcoming[oldLocal].key;
            final newReal = i + 1 + newLocal;
            _p.reorderQueue(oldReal, newReal);
            setBodyState(() {});
          },
          itemBuilder: (_, x) {
            final e = upcoming[x];
            return ListTile(
              key: ValueKey(e.key),
              leading: CoverThumb(
                path: e.value.coverPath,
                url: coverUrlFor(e.value.id),
                size: 44,
              ),
              title: Text(e.value.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(e.value.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(CupertinoIcons.xmark, color: Afisha.inkDim, size: 20),
                    onPressed: () {
                      _p.removeFromQueue(e.key);
                      setBodyState(() {});
                    },
                  ),
                  ReorderableDragStartListener(
                    index: x,
                    child: const Icon(CupertinoIcons.line_horizontal_3, color: Afisha.inkDim),
                  ),
                ],
              ),
              onTap: () {
                _animateQueueTo(0);
                _p.jumpTo(e.key);
              },
            );
          },
        );
      },
    );
  }

  Widget _heartPop() => IgnorePointer(
        child: CompositedTransformFollower(
          link: _favLink,
          targetAnchor: Alignment.center,
          followerAnchor: Alignment.center,
          child: AnimatedBuilder(
            animation: _heart,
            builder: (context, _) {
              final t = _heart.value;
              if (t == 0) return const SizedBox.shrink();
              final scale = 0.6 + Curves.easeOut.transform(t) * 0.9;
              final opacity = t < 0.5 ? t * 2 : (1 - t) * 2;
              return Opacity(
                opacity: opacity.clamp(0, 1),
                child: Transform.scale(
                  scale: scale,
                  // Было 120 — от центра экрана хватало места. Растёт теперь
                  // от кнопки лайка внизу экрана, крупнее — упиралось бы в
                  // край (Опус-ревью «Поток» 23.09.2026, пункт 3).
                  child: const Icon(CupertinoIcons.heart_fill,
                      color: Afisha.lime, size: 90),
                ),
              );
            },
          ),
        ),
      );

}

// ── живой фон: медленно переливается цветами обложки (Alex TG 18608) ──────
// Два цветовых пятна из палитры обложки ходят по кругу в противофазе; ниже —
// затемнение к чёрному, чтобы белый текст читался. Картинки на фоне нет —
// чище и легче для телефона.
class _LivingBackdrop extends StatelessWidget {
  const _LivingBackdrop({required this.anim, required this.colors, required this.img});

  final Animation<double> anim;
  final CoverColors colors;
  // Обложка текущей песни, растянутая и размытая на весь экран (Alex TG
  // 24.09.2026: «облодка как бы размывалась на весь экран», как в
  // Apple Music/Spotify) — под тем же цветным «живым» свечением, что и
  // раньше, оно теперь лежит НА обложке, не на сплошном фоне.
  final ImageProvider? img;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final a = anim.value * 2 * math.pi; // 0..2π за период
        Alignment orbit(double phase, double rx, double ry) => Alignment(
              math.cos(a + phase) * rx,
              math.sin(a + phase) * ry,
            );
        return DecoratedBox(
          decoration: const BoxDecoration(color: Afisha.bg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (img != null)
                // Alex TG 24.09.2026: «замылен, чтобы было видно что это
                // обложка размыта» — было 45, потом 22, потом 12, всё ещё
                // сильно — обложка не узнавалась. Ослабил ещё раз.
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6, tileMode: TileMode.decal),
                  child: Image(image: img!, fit: BoxFit.cover, color: Colors.black.withValues(alpha: 0.12), colorBlendMode: BlendMode.darken),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: orbit(0, 0.7, 0.8),
                    radius: 1.3,
                    colors: [
                      colors.glow.withValues(alpha: 0.55),
                      colors.glow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: orbit(math.pi, 0.8, 0.7),
                    radius: 1.2,
                    colors: [
                      colors.base.withValues(alpha: 0.6),
                      colors.base.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.deep.withValues(alpha: 0.35),
                      Colors.black.withValues(alpha: 0.55),
                      Colors.black,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── инструкция «как пользоваться» внутри приложения ─────────────────────
class _HelpOverlay extends StatelessWidget {
  const _HelpOverlay({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String g, String what) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Afisha.lime, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                          text: '$g — ',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      TextSpan(
                          text: what,
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
            ],
          ),
        );

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          color: Colors.black.withValues(alpha: 0.82),
          alignment: Alignment.center,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            decoration: BoxDecoration(
              color: Afisha.surface,
              // Было 22 — третье своё число рядом с обложкой/плашками (20
              // везде). Опус-ревью «Поток» 23.09.2026, пункт 11.
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Afisha.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Как пользоваться',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('Всё управление — по обложке',
                    style: TextStyle(color: Afisha.inkDim, fontSize: 12)),
                const SizedBox(height: 14),
                row(CupertinoIcons.hand_point_right, 'Тап', 'пауза или играть'),
                row(CupertinoIcons.arrow_left_right, 'Смахнуть вбок', 'следующая / предыдущая песня'),
                row(CupertinoIcons.chevron_up, 'Смахнуть вверх', 'очередь «Дальше»'),
                row(CupertinoIcons.chevron_down, 'Смахнуть вниз', 'свернуть плеер'),
                row(CupertinoIcons.ellipsis, 'Вести по точкам', 'перемотка'),
                row(CupertinoIcons.trash, 'Урна внизу',
                    'убрать песню с телефона совсем (спросит причину)'),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: onClose,
                    child: const Text('Понятно'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

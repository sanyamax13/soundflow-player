import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:solar_icons/solar_icons.dart';

import '../../app/providers.dart';
import '../../core/black_box.dart';
import '../../core/app_log.dart';
import '../../core/config.dart';
import '../../core/fit_text.dart';
import '../../core/format.dart';
import '../../core/genres.dart';
import '../../core/glass_sheet.dart';
import '../../core/local_taste.dart';
import '../../core/notice.dart';
import '../../data/db.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import '../my_music/artist_grouping.dart' show artistKey, artistPartKey, artistsOf, primaryArtist;
import 'cover_art.dart';
import 'cover_palette.dart';
import 'dot_matrix_seek.dart';
import 'seek_skin.dart';
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
/// «меньше такого» остался в «Моей музыке». «Убрать совсем» — кнопкой (урна
/// внизу). План упрощения, п.1-2 и 6.
/// Точечная матрица с цифрами внизу — перемотка (тап или вести пальцем по
/// точкам), см. [DotMatrixSeek]; вариант 19, Alex TG 19.09.2026 (раньше была
/// волна из 64 столбиков с сервера).
///
/// 25.09.2026 (Alex TG): кнопка «радио» (таблетка сверху) переехала в панель
/// «Дальше» внизу — значок ∞ прямо в её строке, пересобирает очередь под
/// играющую песню (та же [_radio], поведение не поменялось, только место).
/// Вопросик сверху (инструкция «как пользоваться») убран как кнопка совсем,
/// без замены — сама подсказка при первом запуске всё ещё показывается один
/// раз ([_maybeShowHelpFirstRun]), просто открыть её повторно теперь негде.
///
/// Общий виджет для двух мест:
///  • вкладка «Поток» вставляет его в тело, без кнопки «вниз»;
///  • [NowPlayingScreen] открывает поверх (тап по мини-плееру), с «вниз».
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key, this.onDismiss, this.emptyState, this.onDismissDrag, this.onDismissDragEnd});

  final VoidCallback? onDismiss;
  final Widget? emptyState;

  /// «Живое» закрытие (27.09.2026, разбор Gemini и Алисы, Alex «делай»): палец тянет плеер вниз
  /// за шапку или обложку — сюда идёт сдвиг по вертикали, на отпускание — скорость. Решает, закрыть
  /// или вернуть, [NowPlayingScreen]. Нет — закрытие только взмахом, как раньше.
  final ValueChanged<double>? onDismissDrag;
  final ValueChanged<double>? onDismissDragEnd;

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

  // Настоящая громкость играющей песни для пляски столбиков эквалайзера
  // (Alex TG 24.09.2026: «чтобы под музыку дрыгалась полоса, а не просто
  // так») — null, пока не досчитана на сервере (см. wavekeeper.go) или
  // ещё грузится; тогда DotMatrixSeek пляшет как раньше, наугад.
  final ValueNotifier<List<double>?> _waveform = ValueNotifier(null);
  final ValueNotifier<Uint8List?> _bass = ValueNotifier(null); // удары баса для пульса кнопки «играть»
  String? _waveformTrackId;

  // Куда «прилетает» сердечко при лайке — центр кнопки лайка в _transport(),
  // а не центр экрана (Опус-ревью «Поток» 23.09.2026, пункт 3: место нажатия
  // и место анимации не совпадали).
  final LayerLink _favLink = LayerLink();

  // Медленный перелив фона под цвет обложки (Alex TG 18608). Обложка не
  // трогается — она якорь.
  late final AnimationController _bg;
  late final AnimationController _heart;
  late final AnimationController _dragX;
  // Смахивание строки «название + исполнитель»: влево — следующая песня, вправо — предыдущая
  // (Alex, голосовое 28.09.2026: «перелистывание свайпом, и чтобы не мешало лайку/удалению» —
  // обложка по-прежнему оставить/удалить). Строка едет за пальцем, как обложка.
  late final AnimationController _titleX = AnimationController.unbounded(vsync: this, value: 0);
  double _titleIn = 1; // откуда въезжает новое название: 1 — справа (следующая), -1 — слева
  // Плашка «Дальше» тянется за пальцем (Alex TG 24.09.2026: «аккуратно за
  // моим пальцем она шла бы, сейчас просто по свайпу поднимается сразу
  // вся») — 0 = свёрнута (только строка «Дальше: …»), 1 = раскрыта на
  // весь список. Значение двигается ЖИВЬЁМ во время onVerticalDragUpdate,
  // а не только по итоговой скорости жеста.
  late final AnimationController _queueOpen;
  late final Animation<double> _queueFade = _queueOpen.drive(const _Clamp01());
  final ValueNotifier<bool> _queueShown = ValueNotifier(false); // шторка хоть чуть раскрыта — строить список
  final ValueNotifier<bool> _queueInteractive = ValueNotifier(false); // раскрыта больше чем наполовину
  final ValueNotifier<bool> _queueCovers = ValueNotifier(false); // раскрыта полностью — плеер под ней замирает
  static const double _queuePeek = 98; // полоска + ряд из 5 кнопок режима с подписями (27.09.2026)
  // «Дыхание» обложки, пока играет: 1.0 ↔ 1.02 за ~4.5 с (разбор Gemini
  // 26.09.2026, моушн «Ambient Flow»). На паузе стоит — батарея и тесты.
  late final AnimationController _breath;

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
    // Без границ: шторку можно чуть «перетянуть» за края — она тянется туже и
    // пружинит назад («резинка», Alex «4 делай», 26.09.2026).
    _queueOpen = AnimationController.unbounded(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() {
        final t = _queueOpen.value;
        _queueShown.value = t > 0.01;
        _queueInteractive.value = t >= 0.6;
        _queueCovers.value = t > 0.97;
      });
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4500),
    );
  }

  void _onPlaying() {
    if (_p.playing.value && _p.now.value != null) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
    }
  }

  void _animateQueueTo(double target, {double velocity = 0}) {
    // Пружина вместо ровной кривой: доезжает с лёгким «отскоком», как в iOS.
    _queueOpen.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 260, damping: 26),
      _queueOpen.value,
      target,
      velocity,
    ));
  }

  // Палец за краем (свёрнута и тянут вниз, раскрыта и тянут вверх) — шторка идёт
  // вчетверо туже и не дальше пары процентов: чувствуется упор, а не обрыв.
  double _queueRaw = 0;
  double _rubber(double raw) {
    if (raw < 0) return math.max(raw * 0.25, -0.05);
    if (raw > 1) return math.min(1 + (raw - 1) * 0.25, 1.04);
    return raw;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wired) {
      _wired = true;
      _controller = ref.read(playerProvider);
      _p.now.addListener(_onNow);
      _p.playing.addListener(_onPlaying);
      _onNow();
      _onPlaying();
      _maybeShowHelpFirstRun();
    }
  }

  @override
  void dispose() {
    _controller?.now.removeListener(_onNow);
    _controller?.playing.removeListener(_onPlaying);
    _breath.dispose();
    _bg.dispose();
    _heart.dispose();
    _dragX.dispose();
    _titleX.dispose();
    _queueOpen.dispose();
    _queueShown.dispose();
    _queueInteractive.dispose();
    _queueCovers.dispose();
    _tint.dispose();
    _waveform.dispose();
    _bass.dispose();
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
    _syncWaveform();
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

  Future<void> _syncWaveform() async {
    final cur = _p.now.value;
    if (cur == null || cur.id == _waveformTrackId) return;
    _waveformTrackId = cur.id;
    _waveform.value = null; // новая песня — пока пляшем наугад, как раньше
    _bass.value = null;
    final api = ref.read(apiProvider);
    final (bars, bass) = await (api.waveform(cur.id), api.bass(cur.id)).wait;
    if (!mounted || _p.now.value?.id != cur.id) return; // трек уже сменился — не подмешиваем чужое
    _waveform.value = bars;
    _bass.value = bass;
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
  // Alex TG 25.09.2026 (по разбору Gemini — «вибро даёт уверенность, что
  // действие сработало, даже если водитель не смотрит на экран»): лёгкий
  // отклик на самые частые нажатия (плей/пауза, лайк, вперёд/назад),
  // потяжелее — на удаление трека.
  Future<void> _toggle() {
    HapticFeedback.lightImpact();
    return _p.toggle();
  }

  /// Урна в виде «Листание»: удаление насовсем — только после подтверждения (кнопку можно задеть
  /// случайно, в отличие от длинного смахивания).
  Future<void> _deleteButton(NowPlaying now) async {
    HapticFeedback.selectionClick();
    final ok = await confirmSheet(context,
        title: 'Удалить песню насовсем?',
        body: '${now.title} — ${now.artist}\nФайл удалится и с компьютера.',
        okLabel: 'Удалить',
        danger: true);
    if (ok && mounted) await _swipeDelete(now);
  }

  Future<void> _toggleFavButton() async {
    final cur = _p.now.value;
    if (cur == null) return;
    HapticFeedback.lightImpact();
    final v = !_fav;
    setState(() => _fav = v);
    await ref.read(downloadsProvider).setFavorite(cur.id, v);
    if (v) _heart.forward(from: 0);
  }

  // «Дальше» / «Назад» плашкой не подписываем: смену песни и так видно по
  // обложке и названию, а плашка на каждый свайп только мельтешила.
  void _swipeNext() {
    HapticFeedback.lightImpact();
    _p.next();
  }

  void _swipePrev() {
    HapticFeedback.lightImpact();
    _p.prev();
  }

  // 26.09.2026 (Alex, голосовое TG 21938 + «1 да так, 2 б, 3 да без вопроса»): «Отбор» убран, его
  // решение переехало сюда — смахнуть обложку вправо = в избранное, влево = удалить насовсем (и с
  // компьютера), без вопроса о причине; в обоих случаях дальше следующая песня. Листать — ⏮ ⏭.
  Future<void> _swipeKeep(NowPlaying now) async {
    HapticFeedback.lightImpact();
    BlackBox.log('swipe_keep', {'id': now.id, 'title': now.title, 'artist': now.artist});
    if (!_fav) {
      setState(() => _fav = true);
      _heart.forward(from: 0);
      unawaited(ref.read(downloadsProvider).setFavorite(now.id, true));
    }
    await _p.next(reportSkip: false);
  }

  Future<void> _swipeDelete(NowPlaying now) async {
    HapticFeedback.heavyImpact();
    BlackBox.log('swipe_delete', {'id': now.id, 'title': now.title, 'artist': now.artist});
    await _p.next(reportSkip: false); // музыка не прерывается — удаление идёт уже за кадром
    final api = ref.read(apiProvider);
    final downloads = ref.read(downloadsProvider);
    try {
      await api.catalogDeleteForever([now.id]); // файл с компьютера — насовсем
    } catch (_) {
      // Нет связи с домом — событие «удалено» с телефона дойдёт само, программа на компьютере
      // доудалит файл (как обычное удаление с телефона).
    }
    await downloads.delete(now.id, reason: 'dislike');
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

  Future<void> _startFilteredRadio(
      Iterable<DownloadedTrack> tracks, NowPlaying now, String message) async {
    final pool = tracks.where((t) => t.id != now.id).toList()..shuffle();
    if (pool.isEmpty) {
      Notice.show('Тут пока нечего поставить', kind: NoticeKind.warn);
      return;
    }
    await _p.setSimilarTail([
      for (final t in pool)
        NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ]);
    // Строка «Дальше: …» внизу читает очередь при перерисовке — без этого после фильтра там
    // оставалась песня из старой очереди (найдено 26.09.2026 на фильтре по жанру).
    if (mounted) setState(() {});
    Notice.show(message);
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
              // Цвет фона переливается к новой обложке за 650 мс, а не щёлкает (Alex «4 делай»).
              ValueListenableBuilder<bool>(
                valueListenable: _queueCovers,
                builder: (_, covered, child) => TickerMode(enabled: !covered, child: child!),
                child: RepaintBoundary(
                child: TweenAnimationBuilder<CoverColors>(
                  tween: _CoverColorsTween(end: colors),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeInOut,
                  builder: (_, c, _) => _LivingBackdrop(anim: _bg, colors: c, img: img),
                ),
              ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _queueCovers,
                builder: (_, covered, child) => TickerMode(enabled: !covered, child: child!),
                child: SafeArea(
                child: Column(
                  children: [
                    _topBar(now),
                    // Обложка занимает ровно столько, сколько осталось после названия,
                    // полосы и кнопок: длинное название в две строки раньше выталкивало
                    // кнопки под шторку «Дальше» (Alex, голосовое TG 26.09.2026: «все
                    // окна одного размера»). Кнопки всегда на одном месте.
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: _coverArea(now, img, colors)),
                      ),
                    ),
                    _titleRow(now),
                    const SizedBox(height: 16),
                    // Полоса обновляется несколько раз в секунду (позиция) — свой слой,
                    // чтобы не тянуть за собой перерисовку остального экрана.
                    RepaintBoundary(
                      child: DotMatrixSeek(
                          controller: _p,
                          tint: colors.isFallback ? Afisha.lime : colors.glow,
                          waveform: _waveform,
                          bass: _bass),
                    ),
                    const SizedBox(height: 12),
                    _transport(colors),
                    const SizedBox(height: 16),
                    const SizedBox(height: _queuePeek),
                  ],
                ),
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

  Widget _topBar(NowPlaying now) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: widget.onDismissDrag == null ? null : (d) => widget.onDismissDrag!(d.delta.dy),
        onVerticalDragEnd:
            widget.onDismissDragEnd == null ? null : (d) => widget.onDismissDragEnd!(d.primaryVelocity ?? 0),
        child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(
          children: [
            if (widget.onDismiss != null)
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(SolarIconsOutline.altArrowDown, color: Colors.white, size: 24),
              )
            else
              const SizedBox(width: 12),
            const Spacer(),
            // Вопросик и кнопка «радио» отсюда убраны (Alex TG 25.09.2026) —
            // см. комментарий у класса выше, куда что переехало.
            // Урны больше нет: удаление — смахнуть обложку влево (26.09.2026, Alex).
            const SizedBox(width: 64, height: 64),
          ],
        ),
      ),
      );


  // Название и исполнитель слева, «сердце» справа на уровне названия (разбор Gemini
  // 26.09.2026, Alex «беру»): под рукой, но в стороне от ряда кнопок плеера.
  // Смена песни — текст уезжает вбок и проявляется новый (200 мс), а не подменяется.
  Future<void> _titleSwipeEnd(DragEndDetails d) async {
    final v = d.primaryVelocity ?? 0;
    final x = _titleX.value;
    final dir = (x <= -80 || (v < -700 && x <= -30))
        ? -1
        : (x >= 80 || (v > 700 && x >= 30))
            ? 1
            : 0;
    if (dir == 0) {
      await _titleX.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack);
      return;
    }
    HapticFeedback.selectionClick();
    _titleIn = dir < 0 ? 1 : -1;
    BlackBox.log(dir < 0 ? 'swipe_title_next' : 'swipe_title_prev', {'id': _p.now.value?.id});
    await _titleX.animateTo(dir * 420.0, duration: const Duration(milliseconds: 140), curve: Curves.easeIn);
    if (dir < 0) {
      await _p.next();
    } else {
      await _p.prev();
    }
    _titleX.value = 0;
  }

  Widget _titleRow(NowPlaying now) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
               key: const ValueKey('player_title_swipe'),
               behavior: HitTestBehavior.opaque,
               onHorizontalDragUpdate: (d) => _titleX.value = (_titleX.value + d.delta.dx).clamp(-260.0, 260.0),
               onHorizontalDragEnd: _titleSwipeEnd,
               child: AnimatedBuilder(
                animation: _titleX,
                builder: (_, child) => Transform.translate(
                  offset: Offset(_titleX.value, 0),
                  child: Opacity(opacity: (1 - _titleX.value.abs() / 320).clamp(0.15, 1.0), child: child),
                ),
                child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...prev, ?cur],
                ),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: Offset(0.06 * _titleIn, 0), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: Column(
                  key: ValueKey(now.id),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Длинное — шрифт сам уменьшается до 18, чтобы влезло целиком (Alex 27.09.2026).
                    FitText(now.title,
                        maxLines: 2,
                        minFontSize: 18,
                        style: const TextStyle(
                            color: Colors.white,
                            // Название крупнее цифр времени (Опус-ревью «Поток» 23.09.2026, п. 2).
                            fontSize: 26,
                            height: 1.15,
                            letterSpacing: -0.5,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    FitText(now.artist,
                        maxLines: 1,
                        minFontSize: 13,
                        fallbackMaxLines: 2,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 18,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              ),
              ),
            ),
            // Цель для сердечка-анимации (_heartPop) — оно прилетает СЮДА, а не
            // в центр экрана (Опус-ревью «Поток» 23.09.2026, пункт 3).
            // Вид «Оценка» — сердечка нет (лайк — смахиванием обложки), остаётся только точка, куда
            // прилетает сердечко-анимация. Вид «Листание» — урна и сердечко (Alex 28.09.2026).
            ValueListenableBuilder<SeekSkin>(
              valueListenable: seekSkin,
              builder: (_, skin, _) => Row(mainAxisSize: MainAxisSize.min, children: [
                if (skin == SeekSkin.glass)
                  _Pressable(
                    key: const ValueKey('player_delete'),
                    onTap: () => _deleteButton(now),
                    child: const SizedBox(
                      width: 64,
                      height: 64,
                      child: Icon(SolarIconsOutline.trashBinTrash, color: Colors.white70, size: 28),
                    ),
                  ),
                CompositedTransformTarget(
                  link: _favLink,
                  child: skin == SeekSkin.glass
                      ? _Pressable(
                          key: const ValueKey('player_fav'),
                          onTap: _toggleFavButton,
                          child: SizedBox(
                            width: 64,
                            height: 64,
                            child: Icon(_fav ? SolarIconsBold.heart : SolarIconsOutline.heart,
                                color: _fav ? Afisha.lime : Colors.white70, size: 30),
                          ),
                        )
                      : const SizedBox(width: 16, height: 64),
                ),
              ]),
            ),
          ],
        ),
      );

  bool? _coverDown;

  Widget _coverArea(NowPlaying now, ImageProvider? img, CoverColors colors) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onHorizontalDragUpdate: (d) {
        _dragX.value = (_dragX.value + d.delta.dx).clamp(-220.0, 220.0);
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        // Порог выше, чем был у «следующая/предыдущая»: удаление насовсем не должно срабатывать
        // от случайного касания.
        // Быстрый взмах засчитываем, только если палец реально прошёл хотя бы 60 точек: иначе
        // короткий рывок в машине удалял бы песню насовсем (ревизия кода 27.09.2026).
        if (seekSkin.value == SeekSkin.glass) {
          // Вид «Листание»: влево — следующая, вправо — предыдущая.
          if (_dragX.value <= -80 || (v < -700 && _dragX.value <= -40)) {
            _swipeNext();
          } else if (_dragX.value >= 80 || (v > 700 && _dragX.value >= 40)) {
            HapticFeedback.lightImpact();
            unawaited(_p.prev());
          }
        } else if (_dragX.value <= -110 || (v < -900 && _dragX.value <= -60)) {
          unawaited(_swipeDelete(now));
        } else if (_dragX.value >= 110 || (v > 900 && _dragX.value >= 60)) {
          unawaited(_swipeKeep(now));
        }
        _dragX.animateTo(0,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      },
      // Первое движение пальца решает: вниз — плеер едет за пальцем (живое закрытие), вверх — очередь.
      onVerticalDragStart: (_) => _coverDown = null,
      onVerticalDragUpdate: (d) {
        _coverDown ??= d.delta.dy > 0;
        if (_coverDown! && widget.onDismissDrag != null) widget.onDismissDrag!(d.delta.dy);
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if ((_coverDown ?? false) && widget.onDismissDragEnd != null) {
          widget.onDismissDragEnd!(v);
        } else if (v > 300) {
          widget.onDismiss?.call();
        } else if (v < -300) {
          _animateQueueTo(1);
        }
        _coverDown = null;
      },
      child: AnimatedBuilder(
        animation: _dragX,
        builder: (context, child) {
          final browse = seekSkin.value == SeekSkin.glass;
          final t = (_dragX.value / (browse ? 80 : 110)).clamp(-1.0, 1.0);
          final glow = browse || t >= 0 ? Afisha.lime : Afisha.red;
          final icon = browse
              ? (t < 0 ? SolarIconsBold.skipNext : SolarIconsBold.skipPrevious)
              : (t >= 0 ? SolarIconsBold.heart : SolarIconsBold.trashBinTrash);
          return Transform.translate(
            offset: Offset(_dragX.value, 0),
            child: Transform.rotate(
              angle: _dragX.value / 1500,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  child!,
                  // Обложка наливается лаймом (оставить) или красным (удалить) изнутри.
                  if (t.abs() > 0.05)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: glow.withValues(alpha: 0.30 * t.abs()),
                                  borderRadius: BorderRadius.circular(32),
                                  border: Border.all(color: glow.withValues(alpha: 0.9 * t.abs()), width: 3),
                                ),
                                child: Icon(icon, color: glow.withValues(alpha: t.abs()), size: 96),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            // Квадрат по свободному месту: самый большой, что влезает и по ширине,
            // и по высоте (см. Expanded в build).
            child: AspectRatio(
              aspectRatio: 1,
            // Hero — тот же тег, что у обложки в мини-плеере (mini_player.dart):
            // при переходе снизу обложка «вырастает» с места мини-плеера, а не
            // пропадает/появляется новая (Опус-ревью «Поток» 23.09.2026,
            // пункт 12, «как в Apple Music»). На вкладке «Поток» этот виджет
            // ни с кем не летает — Hero просто ничего не делает, пока рядом
            // нет второго с тем же тегом.
            child: Hero(
              tag: 'player-cover',
              // Играет — обложка чуть «дышит»; пауза — мягко оседает до 96%.
              child: ValueListenableBuilder<bool>(
                valueListenable: _p.playing,
                builder: (_, pl, child) => AnimatedScale(
                  scale: pl ? 1.0 : 0.96,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  child: child,
                ),
                child: ScaleTransition(
                  scale: Tween(begin: 1.0, end: 1.02)
                      .animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOutSine)),
                  child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Afisha.surfaceHi,
                  // 20 → 32 и тень мягче/ниже (разбор Gemini 26.09.2026, One UI).
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    // Обычная тёмная тень для глубины.
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 40,
                        offset: const Offset(0, 24)),
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  // Смена песни — новая обложка проявляется за 300 мс, а не
                  // подменяется рывком (разбор Gemini 26.09.2026).
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeOutCubic,
                    child: CoverArt(key: ValueKey(now.id), trackId: now.id, localPath: now.coverPath, artist: now.artist),
                  ),
                ),
              ),
                ),
              ),
            ),
          ),
          ),
        ),
      );
  }

  // Разбор Gemini 26.09.2026 (Alex «беру»): в ряду только управление песней —
  // «сердце» уехало к названию, урна — в «•••» сверху. Пауза крупнее (80pt,
  // вслепую в машине), кнопки при нажатии проседают и пружинят обратно,
  // значок play/pause перетекает, а не мигает.
  // Кнопки — скруглённые квадраты (27.09.2026, Alex: «убирай капсулу и ставь скруглённые квадраты,
  // анимации оставь»; вариант Алисы 3 / Gemini Б): «назад/вперёд» — стеклянные 64×64, скругление 22,
  // кромка цвета обложки; «играть» — лаймовый 84×84, скругление 26, пульсирует под бас. Та же форма,
  // что у кнопок режимов и плиток настроения — экран цельный. Значки залитые (видно на солнце),
  // стрелки прыгают при нажатии, «пауза ↔ играть» перетекает.
  Widget _transport(CoverColors colors) {
    final rim = colors.isFallback ? Colors.white.withValues(alpha: 0.14) : _rim(colors.glow).withValues(alpha: 0.55);
    Widget glass(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: rim, width: 1.5),
              ),
              child: child,
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _NudgeButton(
          key: const ValueKey('player_prev'),
          icon: SolarIconsBold.skipPrevious,
          dir: -1,
          onTap: _swipePrev,
          frame: glass,
        ),
        const SizedBox(width: 28),
        ValueListenableBuilder<bool>(
          valueListenable: _p.playing,
          builder: (_, pl, _) => _Pressable(
            key: const ValueKey('player_play'),
            onTap: _toggle,
            child: _BassPulse(
              player: _p,
              bass: _bass,
              radius: 26,
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: Afisha.lime, borderRadius: BorderRadius.circular(26)),
                child: Center(child: _PlayPauseIcon(playing: pl)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 28),
        _NudgeButton(
          key: const ValueKey('player_next'),
          icon: SolarIconsBold.skipNext,
          dir: 1,
          onTap: _swipeNext,
          frame: glass,
        ),
      ],
    );
  }

  // Плашка «Дальше» + список очереди в одном раскрывающемся блоке: свёрнута
  // (высота _queuePeek) — просто строка, ведёшь пальцем — тянется живьём
  // (onVerticalDragUpdate двигает _queueOpen на каждый кадр жеста, а не
  // только по итоговой скорости), отпустил — доезжает до 0 или 1 сама.
  Widget _queueSheet(NowPlaying now) {
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    final dragRange = maxHeight - _queuePeek;
    // Плавность (Alex, голосовое 28.09.2026: «панель выдвигаю — главный экран теряет FPS»): шторка
    // теперь постоянной высоты и едет сдвигом, а не меняет высоту каждый кадр — список очереди не
    // перекладывается заново на каждом кадре жеста. Содержимое (ручка, кнопки, список) строится
    // один раз и передаётся в AnimatedBuilder готовым (child) — на кадре меняются только сдвиг,
    // прозрачность подложки и списка. Анимации плеера под раскрытой шторкой замирают (TickerMode
    // в build), чтобы размытие не пересчитывалось 60 раз в секунду впустую.
    final content = Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _animateQueueTo(_queueOpen.value > 0.5 ? 0 : 1),
          onVerticalDragStart: (_) => _queueRaw = _queueOpen.value.clamp(0.0, 1.0),
          onVerticalDragUpdate: (d) {
            _queueRaw -= d.delta.dy / dragRange;
            _queueOpen.value = _rubber(_queueRaw);
          },
          onVerticalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            final vel = -v / dragRange; // доля высоты в секунду
            if (v < -300) return _animateQueueTo(1, velocity: vel);
            if (v > 300) return _animateQueueTo(0, velocity: vel);
            _animateQueueTo(_queueOpen.value > 0.5 ? 1 : 0, velocity: vel);
          },
          child: _queueHandleRow(now),
        ),
        Expanded(
          child: ValueListenableBuilder<bool>(
            valueListenable: _queueShown,
            builder: (_, shown, _) => !shown
                ? const SizedBox.shrink()
                : FadeTransition(
                    opacity: _queueFade,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _queueInteractive,
                      builder: (_, on, child) => IgnorePointer(ignoring: !on, child: child),
                      child: RepaintBoundary(child: _queueBody(now)),
                    ),
                  ),
          ),
        ),
      ],
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: _queueOpen,
          child: content,
          builder: (context, content) {
            final t = _queueOpen.value;
            return Transform.translate(
              offset: Offset(0, dragRange * (1 - t.clamp(0.0, 1.0))),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                // 25.09.2026 (Alex TG, «начни с 1» — плеер, стекло на карточках):
                // панель «Дальше» была сплошной Afisha.surface — теперь размытый
                // фон + лёгкий блик сверху-слева, тёмная подложка (Afisha.surface)
                // осталась ПОД бликом отдельным слоем — иначе на пёстрой обложке
                // текст очереди было бы не прочитать (тут не плоский чёрный фон,
                // как в apple.dart, а живая картинка).
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: SizedBox(
                    width: double.infinity,
                    height: maxHeight,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(color: Afisha.surface.withValues(alpha: 0.55 + 0.35 * t.clamp(0.0, 1.0))),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(alpha: 0.14),
                                  Colors.white.withValues(alpha: 0.05),
                                  Colors.transparent,
                                ],
                                stops: const [0, 0.4, 1],
                              ),
                              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.16))),
                            ),
                          ),
                        ),
                        content!,
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // 27.09.2026 (Alex, по макету «5 кнопок-значков вместо Дальше»): вместо значка радиоволны с долгим
  // нажатием — пять крупных кнопок, каждая в одно нажатие, включённая лаймовая; повторное нажатие —
  // обычный Поток. Строку «Дальше: …» убрали — очередь видна, если потянуть полоску вверх.
  static const _modes = <(String, IconData, String)>[
    ('similar', SolarIconsBold.soundwave, 'Похожее'),
    ('artist', SolarIconsBold.microphone3, 'Исполнитель'),
    ('favorite', SolarIconsBold.heart, 'Любимое'),
    ('mood', SolarIconsBold.emojiFunnyCircle, 'Настроение'),
    ('genre', SolarIconsBold.musicNote2, 'Жанр'),
  ];

  Widget _queueHandleRow(NowPlaying now) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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
          const SizedBox(height: 6),
          ValueListenableBuilder<String?>(
            valueListenable: _p.radioMode,
            builder: (_, mode, _) => Row(
              children: [
                for (final (key, icon, label) in _modes)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _modeButton(key, icon, mode == key && _modeLabel != null ? _modeLabel! : label,
                          mode == key, now),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String key, IconData icon, String label, bool on, NowPlaying now) {
    // Нажимается всё — и плитка, и подпись: вместе ~70 точек по высоте (правило «не меньше 64» для машины).
    return GestureDetector(
      key: ValueKey('mode_$key'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectMode(key, now),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 52,
            width: double.infinity,
            decoration: BoxDecoration(
              color: on ? Afisha.lime : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 26, color: on ? Colors.black : Colors.white),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: on ? 0.9 : 0.55))),
          ),
        ],
      ),
    );
  }

  /// Режим «что играть дальше» — от ИГРАЮЩЕЙ песни, в одно нажатие, без списков.
  Future<void> _selectMode(String mode, NowPlaying now) async {
    HapticFeedback.selectionClick();
    BlackBox.log('radio_mode', {'mode': mode, 'from': _p.radioMode.value, 'track': now.id});
    // Настроение и Жанр — выбор из списка (Alex TG 21980: «не по той песне, что играет, а вообще выбор»).
    if (mode == 'mood' || mode == 'genre') return _selectFromList(mode, now);
    if (_p.radioMode.value == mode) {
      await _p.stopRadio();
      Notice.show('Обычный Поток', duration: const Duration(seconds: 2));
      return;
    }
    if (_p.radio.value) await _p.stopRadio();
    final hidden = await ref.read(dbProvider).hiddenArtists();
    final all = (await ref.read(downloadsProvider).list()).where((t) => !hidden.contains(t.artist)).toList();
    switch (mode) {
      case 'similar':
        await _radio(now);
      case 'artist':
        // По главному исполнителю, а не по всей строке: у «ILLENIUM feat. Tom Grennan & …» точное
        // совпадение было только у самой этой песни — «Тут пока нечего поставить» (Alex, скрин
        // 27.09.2026). Теперь — все песни ILLENIUM, и с гостями, и без (как папки «Моей музыки»).
        // Несколько исполнителей — спросить, кого слушать дальше (Alex 27.09.2026); один — сразу.
        final names = artistsOf(now.artist);
        if (names.length > 1) {
          final pick = await _pickArtist(names, all, now);
          if (pick == null || !mounted) return;
          final k = artistPartKey(pick);
          await _startFilteredRadio(
              all.where((t) => artistsOf(t.artist).any((n) => artistPartKey(n) == k)), now, 'Дальше — $pick');
        } else {
          final key = artistKey(now.artist);
          await _startFilteredRadio(
              all.where((t) => artistKey(t.artist) == key), now, 'Дальше — ${primaryArtist(now.artist)}');
        }
      case 'favorite':
        await _startFilteredRadio(all.where((t) => t.favorite), now, 'Дальше — любимое');
    }
    if (_p.radio.value) {
      _modeLabel = null;
      _p.radioMode.value = mode;
    }
  }

  /// Что выбрано в «Настроении»/«Жанре» — подпись под кнопкой вместо слова («Рэп», «Бодрое»).
  String? _modeLabel;
  String? _modeKey; // какая плитка сейчас включена — обводится лаймом
  DateTime? _metaRetryAt;

  Future<void> _selectFromList(String mode, NowPlaying now) async {
    final hidden = await ref.read(dbProvider).hiddenArtists();
    var all = (await ref.read(downloadsProvider).list()).where((t) => !hidden.contains(t.artist)).toList();
    if (!mounted) return;
    final active = _p.radioMode.value == mode;
    // 27.09.2026: настроение — настоящее, по звуку (сервер, moodkeeper.go), а не громкость на три части;
    // жанр — 11 больших групп вместо ~96 кодов Яндекса (core/genres.dart).
    String? keyOf(DownloadedTrack t) => mode == 'mood' ? t.mood : genreGroup(t.genre);
    final counts = <String, int>{};
    for (final t in all) {
      final k = keyOf(t);
      if (k != null && k.isNotEmpty) counts[k] = (counts[k] ?? 0) + 1;
    }
    // Пусто — возможно, сервер уже разметил, а телефон ещё не спросил: докачиваем сразу, не ждём
    // ночной докачки (не чаще раза в 10 минут, чтобы без сети не дёргать каталог на каждое нажатие).
    // Для настроения — и когда какого-то из 6 ещё нет (сервер добавил новое, телефон не переспросил).
    final incomplete = counts.isEmpty || (mode == 'mood' && moodOrder.any((o) => !counts.containsKey(o.$1)));
    if (incomplete && DateTime.now().difference(_metaRetryAt ?? DateTime(2000)) > const Duration(minutes: 10)) {
      _metaRetryAt = DateTime.now();
      Notice.show('Подгружаю с компьютера…', duration: const Duration(seconds: 2));
      try {
        await ref.read(downloadsProvider).backfillMeta(force: true);
      } catch (_) {}
      if (!mounted) return;
      all = (await ref.read(downloadsProvider).list()).where((t) => !hidden.contains(t.artist)).toList();
      if (!mounted) return;
      counts.clear();
      for (final t in all) {
        final k = keyOf(t);
        if (k != null && k.isNotEmpty) counts[k] = (counts[k] ?? 0) + 1;
      }
      BlackBox.log('radio_mode', {'mode': mode, 'meta_refetch': counts.length});
    }
    if (counts.isEmpty) {
      Notice.show(mode == 'mood' ? 'Настроение песен ещё считается' : 'Жанры ещё собираются',
          subtitle: 'программа на компьютере разметит их сама — загляни позже', kind: NoticeKind.warn);
      return;
    }
    final order = mode == 'mood' ? moodOrder : genreGroupOrder;
    // Жанр, где меньше 10 песен, не показываем — радио из трёх песен быстро кончится (27.09.2026).
    final tiles = <_Tile>[
      for (final (k, l, e) in order)
        if ((counts[k] ?? 0) >= (mode == 'genre' ? 10 : 1))
          _Tile(k, l, e, count: mode == 'genre' ? counts[k] : null, stripe: mode == 'mood' ? moodColors[k] : null),
    ];
    if (mode == 'genre') tiles.sort((a, b) => (b.count ?? 0).compareTo(a.count ?? 0));
    final pick = await _pickTiles(mode == 'mood' ? 'Настроение' : 'Жанр', tiles, active: active ? _modeKey : null);
    if (pick == null || !mounted) return;
    if (pick == '') {
      await _p.stopRadio();
      Notice.show('Обычный Поток', duration: const Duration(seconds: 2));
      return;
    }
    if (_p.radio.value) await _p.stopRadio();
    final label = order.firstWhere((o) => o.$1 == pick).$2;
    BlackBox.log('radio_mode', {'mode': mode, 'pick': pick});
    await _startFilteredRadio(all.where((t) => keyOf(t) == pick), now, 'Дальше — $label');
    if (_p.radio.value) {
      _modeLabel = label.split(',').first.split(' и ').first; // коротко под кнопкой: «Танцевальная», «Фолк»
      _modeKey = pick;
      _p.radioMode.value = mode;
    }
  }

  /// Кого из исполнителей песни слушать дальше: шторка со строками 64pt — имя и сколько у него ещё
  /// песен на телефоне. Без песен — строка приглушена и не нажимается.
  Future<String?> _pickArtist(List<String> names, List<DownloadedTrack> all, NowPlaying now) {
    final counts = {
      for (final n in names)
        n: all.where((t) => t.id != now.id && artistsOf(t.artist).any((x) => artistPartKey(x) == artistPartKey(n))).length,
    };
    // Выбирать не из чего — не показываем меню ради одной строки.
    final withSongs = [for (final n in names) if (counts[n]! > 0) n];
    if (withSongs.length == 1) return Future.value(withSongs.first);
    if (withSongs.isEmpty) {
      Notice.show('Тут пока нечего поставить',
          subtitle: 'у ${names.map((n) => '«$n»').join(' и ')} других песен на телефоне нет', kind: NoticeKind.warn);
      return Future.value();
    }
    return showGlassSheet<String>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GlassSheetTitle('Кого слушать дальше?'),
          for (final n in names)
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: counts[n]! == 0
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      Navigator.pop(ctx, n);
                    },
              child: SizedBox(
                height: 64,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Icon(SolarIconsBold.microphone3,
                        color: counts[n]! == 0 ? Afisha.inkDim : Afisha.lime, size: 24),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(n,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: counts[n]! == 0 ? Afisha.inkDim : Afisha.ink)),
                    ),
                    Text(counts[n]! == 0 ? 'нет других песен' : '${counts[n]} ${songWord(counts[n]!)}',
                        style: const TextStyle(fontSize: 14, color: Afisha.inkDim)),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Плитки 2 в ряд в стеклянной шторке (27.09.2026, смешанный вариант Gemini и Алисы, Alex
  /// «смешай»): крупный эмодзи и название; у настроения — цветная полоска снизу и без чисел, у жанра —
  /// число песен. Включённая плитка обведена лаймом, сверху «✕ Вернуть обычный Поток» (вернёт '').
  Future<String?> _pickTiles(String title, List<_Tile> tiles, {String? active}) {
    return showGlassSheet<String>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassSheetTitle(title),
          if (active != null) ...[
            GlassSheetButton(label: '✕  Вернуть обычный Поток', onTap: () => Navigator.pop(ctx, '')),
            const SizedBox(height: 12),
          ],
          Flexible(
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              // У жанра — название в две строки и число песен, плитка чуть выше.
              childAspectRatio: tiles.any((t) => t.count != null) ? 1.4 : 1.75,
              children: [for (final t in tiles) _tileView(t, t.key == active, () => Navigator.pop(ctx, t.key))],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileView(_Tile t, bool on, VoidCallback onTap) => Material(
        color: on ? Afisha.lime.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.07),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: on
              ? const BorderSide(color: Afisha.lime, width: 2)
              : BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t.emoji, style: const TextStyle(fontSize: 30)),
                      const SizedBox(height: 4),
                      Text(t.label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, height: 1.15, fontWeight: FontWeight.w600, color: Afisha.ink)),
                      if (t.count != null)
                        Text('${t.count} ${songWord(t.count!)}',
                            style: const TextStyle(fontSize: 12, color: Afisha.inkDim)),
                    ],
                  ),
                ),
              ),
              if (t.stripe != null)
                Positioned(left: 0, right: 0, bottom: 0, height: 3, child: ColoredBox(color: Color(t.stripe!))),
            ],
          ),
        ),
      );

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
                    icon: const Icon(SolarIconsOutline.closeCircle, color: Afisha.inkDim, size: 20),
                    onPressed: () {
                      _p.removeFromQueue(e.key);
                      setBodyState(() {});
                    },
                  ),
                  ReorderableDragStartListener(
                    index: x,
                    child: const Icon(SolarIconsOutline.hamburgerMenu, color: Afisha.inkDim),
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
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Искры разлетаются от сердечка (отложенная анимация из разбора Gemini
                  // «Сейчас играет», Alex «делай» 27.09.2026).
                  CustomPaint(size: const Size(220, 220), painter: _SparksPainter(_heart)),
                  Opacity(
                    opacity: opacity.clamp(0, 1),
                    child: Transform.scale(
                      scale: scale,
                      // Было 120 — от центра экрана хватало места. Растёт теперь
                      // от кнопки лайка внизу экрана, крупнее — упиралось бы в
                      // край (Опус-ревью «Поток» 23.09.2026, пункт 3).
                      child: const Icon(SolarIconsBold.heart,
                          color: Afisha.lime, size: 90),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );

}

/// 12 лаймовых искр по кругу: вылетают от центра с замедлением, уменьшаются и гаснут.
/// Перерисовывается сама по [anim] — без перестройки экрана на каждый кадр.
class _SparksPainter extends CustomPainter {
  _SparksPainter(this.anim) : super(repaint: anim);

  final Animation<double> anim;

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    final fly = Curves.easeOutCubic.transform(t);
    final paint = Paint()..color = Afisha.lime.withValues(alpha: (1 - t).clamp(0.0, 1.0));
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6 + (i.isOdd ? 0.26 : 0);
      final dist = (i.isOdd ? 70.0 : 96.0) * fly;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (18 + dist), (i.isOdd ? 3.5 : 5) * (1 - t * 0.7), paint);
    }
  }

  @override
  bool shouldRepaint(_SparksPainter old) => old.anim != anim;
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
    // Размытая обложка — отдельный неподвижный слой: размытие 50 дорогое, а
    // перелив ниже меняется каждый кадр. Без своей границы весь этот блюр
    // пересчитывался бы 60 раз в секунду (26.09.2026, вместе с размытием 50).
    final blurred = img == null
        ? null
        : RepaintBoundary(
            // История: 45 → 22 → 12 → 6 (Alex TG 24.09.2026, «чтобы было видно,
            // что это обложка»). 26.09.2026 по разбору Gemini Alex сам выбрал
            // сильное «стеклянное» размытие 50 («10 давай 50»).
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
              child: Image(image: img!, fit: BoxFit.cover, color: Colors.black.withValues(alpha: 0.12), colorBlendMode: BlendMode.darken),
            ),
          );
    return AnimatedBuilder(
      animation: anim,
      child: blurred,
      builder: (context, blurredChild) {
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
              ?blurredChild,
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
                row(SolarIconsOutline.arrowRight, 'Тап', 'пауза или играть'),
                row(SolarIconsOutline.heart, 'Смахнуть вправо', 'в избранное и дальше'),
                row(SolarIconsOutline.trashBinTrash, 'Смахнуть влево', 'удалить насовсем (и с компьютера) и дальше'),
                row(SolarIconsOutline.altArrowUp, 'Смахнуть вверх', 'очередь «Дальше»'),
                row(SolarIconsOutline.altArrowDown, 'Смахнуть вниз', 'свернуть плеер'),
                row(SolarIconsOutline.menuDots, 'Вести по точкам', 'перемотка'),
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

// Кнопка, которая при касании проседает до 85% и пружинит обратно (разбор Gemini
// 26.09.2026: живой отклик, как в iOS). Вибрацию даёт сам обработчик (_toggle и т.п.).
class _Pressable extends StatefulWidget {
  const _Pressable({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.85 : 1.0,
        duration: Duration(milliseconds: _down ? 80 : 260),
        curve: _down ? Curves.easeOutQuad : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

class _CoverColorsTween extends Tween<CoverColors> {
  _CoverColorsTween({super.end});

  @override
  CoverColors lerp(double t) => (begin ?? end!).lerpTo(end!, t);
}

/// Плитка выбора настроения/жанра.
class _Tile {
  const _Tile(this.key, this.label, this.emoji, {this.count, this.stripe});
  final String key;
  final String label;
  final String emoji;
  final int? count;
  final int? stripe;
}

/// «Играть» перетекает в «пауза» и обратно за 300 мс, а не подменяется (совет Gemini 27.09.2026).
class _PlayPauseIcon extends StatefulWidget {
  const _PlayPauseIcon({required this.playing});
  final bool playing;

  @override
  State<_PlayPauseIcon> createState() => _PlayPauseIconState();
}

class _PlayPauseIconState extends State<_PlayPauseIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(_PlayPauseIcon old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      widget.playing ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedIcon(
        icon: AnimatedIcons.play_pause,
        progress: CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic),
        color: const Color(0xFF1C1C1C),
        size: 38,
      );
}

/// Цвет кромки капсулы из цвета обложки: той же тональности, но светлее и насыщеннее, чтобы
/// светился и на тёмной обложке.
Color _rim(Color c) {
  final h = HSLColor.fromColor(c);
  return h.withLightness(h.lightness.clamp(0.55, 0.7)).withSaturation(h.saturation.clamp(0.5, 1.0)).toColor();
}

/// «Назад/вперёд» в капсуле: на нажатие стрелка коротко прыгает в свою сторону и пружинит обратно
/// (Alex «2+3+4», 27.09.2026). Зона нажатия — вся половина капсулы, высота 88.
class _NudgeButton extends StatefulWidget {
  const _NudgeButton({super.key, required this.icon, required this.dir, required this.onTap, this.frame});
  final IconData icon;
  final double dir;
  final VoidCallback onTap;

  /// Подложка вокруг стрелки (стеклянный скруглённый квадрат); зона нажатия всё равно 80×88.
  final Widget Function(Widget child)? frame;

  @override
  State<_NudgeButton> createState() => _NudgeButtonState();
}

class _NudgeButtonState extends State<_NudgeButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _c.forward(from: 0);
          widget.onTap();
        },
        child: SizedBox(
          width: 80,
          height: 88,
          child: Center(
            child: (widget.frame ?? (w) => w)(AnimatedBuilder(
              animation: _c,
              builder: (_, child) {
                final t = _c.value;
                // быстрый толчок на ~10 точек и затухающая пружинка обратно
                final dx = math.sin(t * math.pi * 2.2) * (1 - t) * 10 * widget.dir;
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: Center(child: Icon(widget.icon, color: Colors.white, size: 28)),
            )),
          ),
        ),
      );
}

/// Пульс кнопки «играть» под бас (Alex 27.09.2026: «от кнопки плей пульсация под басы»): каждый
/// кадр смотрит, какое место песни играет, берёт отметку баса (20 в секунду, с сервера) — на удар
/// вспыхивает лаймовое свечение и кнопка чуть подрастает, дальше гаснет само (~120 мс). Отметок нет
/// (ещё не посчитаны, нет связи) — спокойно «дышит» раз в 3 секунды. На паузе — замирает. Кадры
/// идут только когда экран виден (TickerMode скрытых вкладок их останавливает).
class _BassPulse extends StatefulWidget {
  const _BassPulse({required this.player, required this.bass, required this.child, this.radius});
  final PlayerController player;

  /// Скругление свечения — как у кнопки (null — круг).
  final double? radius;
  final ValueNotifier<Uint8List?> bass;
  final Widget child;

  @override
  State<_BassPulse> createState() => _BassPulseState();
}

class _BassPulseState extends State<_BassPulse> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _g = ValueNotifier(0);
  Duration _last = Duration.zero;
  Duration _posAt = Duration.zero; // позиция из плеера и когда она пришла — между ними досчитываем
  DateTime _posTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.player.position.addListener(_onPos);
    widget.player.playing.addListener(_onPlaying);
    _onPlaying();
  }

  void _onPos() {
    _posAt = widget.player.position.value;
    _posTime = DateTime.now();
  }

  void _onPlaying() {
    if (widget.player.playing.value) {
      _onPos();
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    } else {
      if (_ticker.isActive) _ticker.stop();
      _g.value = 0;
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final env = widget.bass.value;
    double e;
    if (env != null && env.isNotEmpty) {
      final pos = _posAt + DateTime.now().difference(_posTime);
      final i = pos.inMilliseconds ~/ 50;
      e = (i >= 0 && i < env.length) ? env[i] / 255.0 : 0;
    } else {
      e = 0.25 + 0.2 * math.sin(elapsed.inMilliseconds / 3000 * 2 * math.pi); // «дыхание»
    }
    final decayed = _g.value * math.exp(-dt / 0.12);
    _g.value = math.max(e, decayed);
  }

  @override
  void dispose() {
    widget.player.position.removeListener(_onPos);
    widget.player.playing.removeListener(_onPlaying);
    _ticker.dispose();
    _g.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: _g,
        child: widget.child,
        builder: (_, g, child) => Transform.scale(
          scale: 1 + 0.07 * g,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: widget.radius == null ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: widget.radius == null ? null : BorderRadius.circular(widget.radius!),
              boxShadow: [
                BoxShadow(
                  color: Afisha.lime.withValues(alpha: 0.18 + 0.5 * g),
                  blurRadius: 12 + 22 * g,
                  spreadRadius: 1 + 5 * g,
                ),
              ],
            ),
            child: child,
          ),
        ),
      );
}

/// Значение шторки очереди может чуть выходить за 0..1 («резинка»); прозрачности нужно строго 0..1.
class _Clamp01 extends Animatable<double> {
  const _Clamp01();
  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}

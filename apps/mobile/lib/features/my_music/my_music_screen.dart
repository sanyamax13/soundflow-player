import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/cover_thumb.dart';
import '../../core/format.dart';
import '../../core/notice.dart';
import '../../core/apple.dart';
import '../../core/glass_sheet.dart';
import '../../core/theme.dart';
import '../../core/removal_reasons.dart';
import '../../data/db.dart';
import '../../data/downloads_repo.dart';
import '../sync/sync_offer_card.dart';
import '../player/player_controller.dart';
import 'artist_grouping.dart';

/// «Моя музыка» — вид «Б» (Alex TG 20134, 20.09.2026): ВСЕ исполнители папками
/// (даже с одной песней) по алфавиту — латиница, кириллица, «#» — с полоской
/// букв справа; сверху поиск по исполнителю и названию; вместо серой ноты
/// цветная плитка с буквами; название в две строки; в шапке только «N песни».
/// Тап по исполнителю — его песни.
///
/// Разные написания одного исполнителя («9 грамм», «9 Грамм»,
/// «9 грамм, Artizio», «9 Грамм feat. Miyagi») собираются в одну «папку» —
/// см. artist_grouping.dart (Alex TG 18687). Песни с нечитаемым именем —
/// строка «Имя не читается» сверху (Alex TG 18688), песни — в листе по нажатию.
class MyMusicScreen extends ConsumerStatefulWidget {
  const MyMusicScreen({super.key});

  @override
  ConsumerState<MyMusicScreen> createState() => _MyMusicScreenState();
}

/// Высоты фиксированные: по ним считаем, куда прыгать при движении пальца по
/// полоске букв (список на тысячи строк — строить всё ради измерения нельзя).
const double _kRowH = 76;
const double _kHeaderH = 32;
const double _kMoreH = 44;
// 24 → 44: шире под палец в машине (разбор Gemini 26.09.2026, «Моя музыка»).
const double _kRailW = 44;
const int _kMaxArtistHits = 30;
const int _kMaxSongHits = 150;

/// Запись плоского списка: буква-заголовок или исполнитель.
class _Entry {
  const _Entry.header(this.letter) : folder = null;
  const _Entry.folder(this.folder) : letter = null;
  final String? letter;
  final ArtistFolder? folder;
}

class _SongHit {
  const _SongHit(this.track, this.index);
  final DownloadedTrack track;
  final int index;
}

class _More {
  const _More(this.text);
  final String text;
}

class _SearchResult {
  const _SearchResult(this.artists, this.songs, this.rows);
  final List<ArtistFolder> artists;
  final List<DownloadedTrack> songs;

  /// Всё, что рисуем: строки-заголовки (String), исполнители, найденные песни,
  /// «и ещё N» (_More).
  final List<Object> rows;
}

class _MyMusicScreenState extends ConsumerState<MyMusicScreen> {
  bool _onlyFav = false;
  List<DownloadedTrack>? _items;
  List<ArtistFolder> _folders = const [];
  int _count = 0;

  /// Ключ открытой папки исполнителя — null, если показываем список.
  String? _openKey;

  /// Какие строки страницы исполнителя уже «проявились» (появление лесенкой — один раз на страницу).
  final _staggered = <int>{};

  // Алфавитный список: плоские записи, буквы полоски и куда за какой прыгать.
  List<_Entry> _entries = const [];
  List<String> _letters = const [];
  final Map<String, double> _letterOffset = {};
  final ValueNotifier<String> _activeLetter = ValueNotifier('');
  final ValueNotifier<String?> _railShown = ValueNotifier(null);
  final ScrollController _scroll = ScrollController();

  // Поиск: свёрнутые исполнитель / название / оба вместе — по одному на песню из _items.
  final TextEditingController _searchCtl = TextEditingController();
  List<String> _foldArtist = const [];
  List<String> _foldTitle = const [];
  List<String> _hay = const [];
  String _memoQuery = '';
  _SearchResult? _memo;

  final Map<String, String?> _covers = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) {
      final d = ref.read(downloadsProvider);
      d.changes.addListener(_onLibraryChanged);
      _downloads = d;
      _refresh();
    }
  }

  // Песни на телефоне поменялись (докачалась пачка, убрали) — перечитать список.
  // Во время закачки события идут часто, поэтому с задержкой: одно обновление
  // на серию, а не на каждую песню.
  DownloadsRepo? _downloads;
  Timer? _libraryDebounce;
  void _onLibraryChanged() {
    _libraryDebounce?.cancel();
    _libraryDebounce = Timer(const Duration(milliseconds: 700), () {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _downloads?.changes.removeListener(_onLibraryChanged);
    _libraryDebounce?.cancel();
    _scroll.dispose();
    _searchCtl.dispose();
    _activeLetter.dispose();
    _railShown.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final d = ref.read(downloadsProvider);
    var items = await d.list(onlyFavorite: _onlyFav);

    // Одноразовые правки битых тегов (Alex TG 18693): известное имя —
    // переименовать, безнадёжно сломанное — убрать.
    var patched = false;
    for (final t in List<DownloadedTrack>.from(items)) {
      final fix = kTagFixes[t.id];
      if (fix != null && (t.artist != fix.artist || t.title != fix.title)) {
        await d.rename(t.id, artist: fix.artist, title: fix.title);
        patched = true;
      } else if (kDropBrokenIds.contains(t.id)) {
        await d.delete(t.id, reason: 'broken_tag');
        patched = true;
      }
    }
    if (patched) items = await d.list(onlyFavorite: _onlyFav);

    // Нужно только число песен — не полная сводка (она проверяла обложки на диске).
    final s = await d.stats();
    final g = groupArtists(items);
    if (!mounted) return;
    setState(() {
      _items = items;
      // Песни с нечитаемым именем — обычной папкой в конце списка (27.09.2026: отдельный лист
      // «Имя не читается» с «Исправить имя» убран, имена чистит программа на компьютере сама).
      _folders = [...g.folders, if (g.broken.isNotEmpty) _BrokenFolder(g.broken)];
      _count = s.count;
      _covers.clear();
      _foldArtist = [for (final t in items) foldName(t.artist)];
      _foldTitle = [for (final t in items) foldName(t.title)];
      _hay = [
        for (var i = 0; i < items.length; i++)
          '${_foldArtist[i]} ${_foldTitle[i]}',
      ];
      _memo = null;
      _buildEntries();
      // папка могла остаться без песен (всё удалили) — вернуться к списку
      if (_openKey != null && !_folders.any((f) => f.key == _openKey)) {
        _openKey = null;
        _staggered.clear();
      }
    });
  }

  /// Плоский список «буква, исполнители буквы, буква, …» и смещение каждой
  /// буквы от начала списка (строки фиксированной высоты — считаем, не меряем).
  void _buildEntries() {
    final entries = <_Entry>[];
    final letters = <String>[];
    _letterOffset.clear();
    var y = 0.0;
    String? cur;
    for (final f in _folders) {
      if (f.letter != cur) {
        cur = f.letter;
        letters.add(f.letter);
        _letterOffset[f.letter] = y;
        entries.add(_Entry.header(f.letter));
        y += _kHeaderH;
      }
      entries.add(_Entry.folder(f));
      y += _kRowH;
    }
    _entries = entries;
    _letters = letters;
    if (!letters.contains(_activeLetter.value)) {
      _activeLetter.value = letters.isEmpty ? '' : letters.first;
    }
  }

  void _onScroll() {
    if (_letters.isEmpty || !_scroll.hasClients) return;
    final p = _scroll.position.pixels;
    var cur = _letters.first;
    for (final l in _letters) {
      if ((_letterOffset[l] ?? 0) <= p + 1) {
        cur = l;
      } else {
        break;
      }
    }
    if (_activeLetter.value != cur) _activeLetter.value = cur;
  }

  void _jumpToLetter(String letter) {
    final off = _letterOffset[letter];
    if (off == null || !_scroll.hasClients) return;
    _scroll.jumpTo(off.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
  }

  /// Обложка исполнителя — первая из его песен, что реально лежит на диске.
  /// Запоминаем: на каждый кадр прокрутки опрашивать диск по всем песням папки дорого.
  String? _artistCover(ArtistFolder f) => _covers.putIfAbsent(f.key, () {
    for (final t in f.tracks) {
      final p = t.coverPath;
      if (p != null && p.isNotEmpty && File(p).existsSync()) return p;
    }
    return null;
  });

  Future<void> _playList(
    List<DownloadedTrack> list,
    int startIndex, {
    bool shuffle = false,
  }) async {
    final queue = [
      for (final x in list)
        NowPlaying(
          id: x.id,
          title: x.title,
          artist: x.artist,
          path: x.path,
          coverPath: x.coverPath,
        ),
    ];
    await ref
        .read(playerProvider)
        .playQueue(
          queue,
          startIndex: startIndex < 0 ? 0 : startIndex,
          shuffle: shuffle,
        );
  }

  Future<void> _toggleFav(DownloadedTrack t) async {
    await ref.read(downloadsProvider).setFavorite(t.id, !t.favorite);
    await _refresh();
  }

  // Шторка снизу в общем стиле (core/glass_sheet.dart), а не серое окно посреди экрана.
  Future<bool> _confirm(String title, String body, String okLabel) =>
      confirmSheet(context, title: title, body: body, okLabel: okLabel, danger: true);

  /// Раньше рядом лежали два похожих пункта — «Не та версия» (удаляла файл
  /// СРАЗУ, без вопроса) и «Удалить песню» (спрашивала да/нет, но не
  /// причину) — Alex не мог понять разницу (Опус-ревью телефона 14.09.2026,
  /// пункт 9). Теперь один и тот же лист причин, что и в плеере
  /// (core/removal_reasons.dart) — выбор причины и есть подтверждение.
  Future<void> _removeCompletely(DownloadedTrack t) async {
    final reason = await pickRemovalReason(context);
    if (reason == null || !mounted) return;
    await ref.read(downloadsProvider).delete(t.id, reason: reason.isEmpty ? null : reason); // '' — «Без причины»
    await _refresh();
  }

  /// Мягкий сигнал «не по вкусу» — файл не трогает, только влияет на будущий
  /// подбор (тот же принцип, что и «меньше такого» в плеере). Раньше на этом
  /// экране такого действия не было вообще — только жёсткое удаление.
  Future<void> _lessLike(DownloadedTrack t) async {
    await ref.read(syncProvider).record('less_like', trackId: t.id);
    Notice.show('Буду реже ставить похожее');
  }

  Future<void> _deleteArtist(ArtistFolder folder) async {
    final d = ref.read(downloadsProvider);
    if (!await _confirm(
      'Удалить всего исполнителя?',
      '«${folder.display}» — ${folder.count} ${songWord(folder.count)}. '
          'Все файлы сотрутся с телефона. Скачать заново можно с сервера.',
      'Удалить всё',
    )) {
      return;
    }
    for (final t in folder.tracks) {
      await d.delete(t.id);
    }
    if (mounted) {
      _staggered.clear();
      setState(() => _openKey = null);
    }
    await _refresh();
  }

  // ─── поиск ─────────────────────────────────────────────────────────────
  /// Исполнители и песни, где встречаются ВСЕ слова запроса (по свёрнутым
  /// именам: регистр, «ё», надстрочные знаки не мешают). Песни ищем по строке
  /// «исполнитель название» — «depeche jesus» найдёт «Personal Jesus».
  _SearchResult _search(String rawQuery) {
    final q = foldName(rawQuery).trim();
    final memo = _memo;
    if (memo != null && _memoQuery == q) return memo;
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final items = _items ?? const <DownloadedTrack>[];

    final allArtists = [
      for (final f in _folders)
        if (words.every(f.folded.contains)) f,
    ];
    // Сперва те, чьё имя НАЧИНАЕТСЯ с запроса, потом остальные (алфавит внутри сохраняется).
    final first = words.first;
    final ordered = [
      ...allArtists.where((f) => f.folded.startsWith(first)),
      ...allArtists.where((f) => !f.folded.startsWith(first)),
    ];
    final artists = ordered.take(_kMaxArtistHits).toList();

    final hits = <int>[
      for (var i = 0; i < items.length; i++)
        if (words.every(_hay[i].contains)) i,
    ];
    int score(int i) => _foldTitle[i].startsWith(first)
        ? 0
        : (_foldArtist[i].startsWith(first) ? 1 : 2);
    hits.sort((a, b) {
      final sa = score(a), sb = score(b);
      if (sa != sb) return sa - sb;
      final c = _foldArtist[a].compareTo(_foldArtist[b]);
      return c != 0 ? c : _foldTitle[a].compareTo(_foldTitle[b]);
    });
    final songs = [for (final i in hits.take(_kMaxSongHits)) items[i]];

    final rows = <Object>[
      if (artists.isNotEmpty) 'Исполнители',
      ...artists,
      if (ordered.length > artists.length)
        _More('и ещё ${ordered.length - artists.length} — уточни запрос'),
      if (songs.isNotEmpty) 'Песни',
      for (var i = 0; i < songs.length; i++) _SongHit(songs[i], i),
      if (hits.length > songs.length)
        _More('и ещё ${hits.length - songs.length} — уточни запрос'),
    ];
    final res = _SearchResult(artists, songs, rows);
    _memoQuery = q;
    _memo = res;
    return res;
  }

  void _openFolder(ArtistFolder f) {
    FocusManager.instance.primaryFocus?.unfocus();
    _staggered.clear();
    setState(() => _openKey = f.key);
  }

  @override
  Widget build(BuildContext context) {
    final key = _openKey;
    final folder = key == null
        ? null
        : _folders.firstWhere(
            (f) => f.key == key,
            orElse: () => ArtistFolder(key, key, const []),
          );
    // Список остаётся в дереве (просто спрятан), пока открыта папка: так не
    // теряются место прокрутки и набранный поиск, когда возвращаешься «назад».
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: folder != null, child: _artistList()),
        // Страница исполнителя «выезжает из глубины»: 0.95 → 1 и проявление
        // за 300 мс (разбор Gemini 26.09.2026).
        if (folder != null)
          TweenAnimationBuilder<double>(
            key: ValueKey(folder.key),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.fastOutSlowIn,
            builder: (_, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.95 + 0.05 * t, child: child),
            ),
            child: _artistDetail(folder),
          ),
      ],
    );
  }

  // ─── список исполнителей ───────────────────────────────────────────────
  Widget _artistList() {
    final searching = _searchCtl.text.trim().isNotEmpty;
    final n = _onlyFav ? (_items?.length ?? 0) : _count;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppleLargeTitle('Моя музыка'),
                  if (_items != null)
                    Text(
                      _onlyFav
                          ? '${fmtInt(n)} ${songWord(n)} в избранном'
                          : '${fmtInt(n)} ${songWord(n)} на телефоне',
                      style: const TextStyle(
                        color: Afisha.inkDim,
                        fontSize: 12.5,
                      ),
                    ),
                  const SizedBox(height: 8),
                  _searchField(),
                  const SizedBox(height: 8),
                  AppleSegmented<bool>(
                    options: const {false: 'Все', true: 'Избранное'},
                    selected: _onlyFav,
                    onChanged: (v) {
                      setState(() => _onlyFav = v);
                      _refresh();
                    },
                  ),
                ],
              ),
            ),
            const SyncOfferCard(),
            const Divider(height: 0.5, thickness: 0.5, color: Afisha.sep),
            Expanded(
              child: _items == null
                  ? const Center(child: CircularProgressIndicator())
                  : searching
                  ? _searchResults()
                  : _folders.isEmpty
                  ? _empty()
                  : _alphabetList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField() => TextField(
    controller: _searchCtl,
    onChanged: (_) => setState(() {}),
    textInputAction: TextInputAction.search,
    style: const TextStyle(fontSize: 15),
    decoration: InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Afisha.surfaceHi,
      hintText: 'Поиск: песня или исполнитель',
      hintStyle: const TextStyle(color: Afisha.inkDim, fontSize: 15),
      prefixIcon: const Icon(
        CupertinoIcons.search,
        color: Afisha.inkDim,
        size: 19,
      ),
      suffixIcon: _searchCtl.text.isEmpty
          ? null
          : IconButton(
              icon: const Icon(
                CupertinoIcons.xmark_circle_fill,
                color: Afisha.inkDim,
                size: 18,
              ),
              onPressed: () => setState(_searchCtl.clear),
            ),
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );

  // Алфавитный список + полоска букв справа. Строки фиксированной высоты
  // (`SliverVariedExtentList`) — чтобы прыжок по букве был точным.
  Widget _alphabetList() {
    final entries = _entries;
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.only(right: _kRailW),
                sliver: SliverVariedExtentList(
                  itemExtentBuilder: (i, _) =>
                      entries[i].letter != null ? _kHeaderH : _kRowH,
                  delegate: SliverChildBuilderDelegate((_, i) {
                    final e = entries[i];
                    final l = e.letter;
                    return l != null ? _letterHeader(l) : _artistRow(e.folder!);
                  }, childCount: entries.length),
                ),
              ),
              // Низ списка не прячется под стеклянным мини-плеером и меню
              // (они теперь поверх содержимого, shell.dart extendBody).
              SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom)),
            ],
          ),
        ),
        // 25.09.2026 (Gemini): было right:0 — палец при скролле перекрывал
        // половину алфавита у самого края экрана. Небольшой отступ от края.
        Positioned(right: 5, top: 4, bottom: 4, width: _kRailW, child: _rail()),
        // Крупная буква посреди экрана, пока ведёшь пальцем по полоске.
        Center(
          child: ValueListenableBuilder<String?>(
            valueListenable: _railShown,
            builder: (_, l, _) => l == null
                ? const SizedBox.shrink()
                // Стеклянный квадрат 100×100 с буквой 40pt — видно, куда прыгнул,
                // не глядя на палец (разбор Gemini 26.09.2026).
                : ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        width: 100,
                        height: 100,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                        ),
                        child: Text(
                          l,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 40,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// Полоска букв: палец ведёт по ней — список прыгает на букву. Букв бывает
  /// ~55 (латиница + кириллица), на низком экране подписываем каждую вторую-
  /// третью, остальные — точки; прыгать можно на любую.
  Widget _rail() {
    final letters = _letters;
    if (letters.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        final slot = h / letters.length;
        // буквы 12pt (было 9.5 — мелко для машины, вердикт Gemini 26.09.2026)
        final step = slot >= 15 ? 1 : (15 / slot).ceil();
        void go(double dy) {
          final i = (dy / h * letters.length).floor().clamp(
            0,
            letters.length - 1,
          );
          _railShown.value = letters[i];
          _jumpToLetter(letters[i]);
        }

        void done() => _railShown.value = null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => go(d.localPosition.dy),
          onTapUp: (_) => done(),
          onTapCancel: done,
          onVerticalDragStart: (d) => go(d.localPosition.dy),
          onVerticalDragUpdate: (d) => go(d.localPosition.dy),
          onVerticalDragEnd: (_) => done(),
          onVerticalDragCancel: done,
          child: ValueListenableBuilder<String>(
            valueListenable: _activeLetter,
            builder: (_, cur, _) => Column(
              children: [
                // OverflowBox: клетка буквы бывает ниже самой буквы (~8 px на 55
                // букв) — пусть буква выходит за клетку, а не сжимается.
                for (var i = 0; i < letters.length; i++)
                  Expanded(
                    child: OverflowBox(
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: _kRailW,
                      maxHeight: 22,
                      child: letters[i] == cur
                          ? Container(
                              width: 20,
                              height: 20,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: Afisha.lime,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                letters[i],
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 12,
                                  height: 1,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : i % step == 0
                          ? Text(
                              letters[i],
                              style: const TextStyle(
                                color: Afisha.inkDim,
                                fontSize: 12,
                                height: 1,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : Container(
                              width: 2.5,
                              height: 2.5,
                              decoration: const BoxDecoration(
                                color: Afisha.line,
                                shape: BoxShape.circle,
                              ),
                            ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 25.09.2026 (по разбору Gemini, Alex «да меняй»): буквы-разделители были
  // ярко-лаймовые — «кричали» на весь список. Приглушены до почти-белого,
  // помельче, но с большим трекингом — работают как структурная сетка, а
  // не как акцент.
  Widget _letterHeader(String l) => Container(
    height: _kHeaderH,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.only(left: 18),
    color: Afisha.bg,
    child: Text(
      l,
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 2.0,
      ),
    ),
  );

  /// Общая строка списка: плитка, название в две строки, подпись, справа — своё.
  Widget _rowShell({
    required VoidCallback onTap,
    required Widget leading,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) => _PressRow(
    onTap: onTap,
    child: Container(
      height: _kRowH,
      padding: const EdgeInsets.only(left: 16, right: 4),
      // Разделитель как в iOS: тонкая линия, начинается от текста, а не от края экрана.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Линий между строками больше нет — хватает отступов (вердикт Gemini
          // 26.09.2026: в iOS/One UI разделители — лишний шум).
          Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      // 25.09.2026 (Gemini): было 16 — чуть крупнее для
                      // контраста с подписью под именем.
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // 13 серым → 14 Medium, 55% белого (разбор Gemini 26.09.2026).
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ],
      ),
    ),
  );

  Widget _artistRow(ArtistFolder f) => _rowShell(
    onTap: () => _openFolder(f),
    leading: CoverThumb(
      path: _artistCover(f),
      url: f.tracks.isNotEmpty ? coverUrlFor(f.tracks.first.id) : null,
      size: 56,
      radius: 12,
      label: f.display,
    ),
    title: f.display,
    subtitle: '${f.count} ${songWord(f.count)}',
    trailing: _moreButton(() async {
      final v = await showAppleActionSheet<String>(
        context,
        title: f.display,
        actions: const [
          SheetAction('play', 'Играть всё', CupertinoIcons.play_fill),
          SheetAction('shuffle', 'Вперемешку', CupertinoIcons.shuffle),
          SheetAction('delete', 'Удалить всего исполнителя', CupertinoIcons.trash, destructive: true),
        ],
      );
      switch (v) {
        case 'play':
          _playList(f.tracks, 0);
        case 'shuffle':
          _playList(f.tracks, 0, shuffle: true);
        case 'delete':
          _deleteArtist(f);
      }
    }),
  );

  // «•••» справа, зона нажатия 64×64 (разбор Gemini 26.09.2026).
  Widget _moreButton(VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: const SizedBox(
      width: 64,
      height: 64,
      child: Center(
        child: Icon(CupertinoIcons.ellipsis, color: Afisha.inkDim, size: 22),
      ),
    ),
  );

  /// Строка песни в результатах поиска: плитка, «Название», исполнитель под
  /// ним, сердечко и меню. Тап — играть её и дальше остальные найденные.
  Widget _foundSongRow(_SongHit hit, List<DownloadedTrack> songs) {
    final t = hit.track;
    return _rowShell(
      onTap: () => _playList(songs, hit.index),
      leading: CoverThumb(
        path: t.coverPath,
        url: coverUrlFor(t.id),
        size: 56,
        radius: 12,
        label: primaryArtist(t.artist),
      ),
      title: t.title,
      subtitle: t.artist,
      trailing: _songActions(t),
    );
  }

  // 25.09.2026 (Gemini, Alex «кнопки на 64 точки делай, сам расположишь как
  // надо»): было VisualDensity.compact — тап ещё меньше стандарта. Строка
  // высотой 76 (_kRowH) — 64 помещается, задел под соседние строки есть.
  // Разбор Gemini 26.09.2026 (Alex «8 делай»): сердце видно только у любимых
  // (нажатие — убрать из избранного), добавить — через «•••». Строка чище, в машине
  // меньше шансов попасть не туда. Меню — нижняя шторка с крупными пунктами.
  Widget _songActions(DownloadedTrack t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (t.favorite)
        IconButton(
          constraints: const BoxConstraints(minWidth: 64, minHeight: 64),
          onPressed: () => _toggleFav(t),
          icon: const Icon(CupertinoIcons.heart_fill, color: Afisha.lime, size: 22),
        ),
      _moreButton(() async {
        final v = await showAppleActionSheet<String>(
          context,
          title: '${t.title} — ${t.artist}',
          actions: [
            SheetAction(
              'fav',
              t.favorite ? 'Убрать из избранного' : 'В избранное',
              t.favorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart_fill,
            ),
            const SheetAction('less', 'Меньше такого', CupertinoIcons.hand_thumbsdown),
            const SheetAction('delete', 'Убрать совсем', CupertinoIcons.trash, destructive: true),
          ],
        );
        switch (v) {
          case 'fav':
            _toggleFav(t);
          case 'less':
            _lessLike(t);
          case 'delete':
            _removeCompletely(t);
        }
      }),
    ],
  );

  Widget _searchResults() {
    final res = _search(_searchCtl.text);
    if (res.rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Ничего не нашлось по «${_searchCtl.text.trim()}»',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Afisha.inkDim, height: 1.5),
          ),
        ),
      );
    }
    final rows = res.rows;
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      itemCount: rows.length,
      itemExtentBuilder: (i, _) => switch (rows[i]) {
        String() => _kHeaderH,
        _More() => _kMoreH,
        _ => _kRowH,
      },
      itemBuilder: (_, i) => switch (rows[i]) {
        final String s => Container(
          height: _kHeaderH,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.fromLTRB(18, 0, 0, 6),
          child: Text(
            s.toUpperCase(),
            style: const TextStyle(
              color: Afisha.inkDim,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        final ArtistFolder f => _artistRow(f),
        final _SongHit h => _foundSongRow(h, res.songs),
        final _More m => Container(
          height: _kMoreH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 18),
          child: Text(
            m.text,
            style: const TextStyle(color: Afisha.inkDim, fontSize: 13),
          ),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  // ─── песни одной папки исполнителя ─────────────────────────────────────
  Widget _artistDetail(ArtistFolder folder) {
    // Альбомы в плеере не нужны (Alex TG 21750, 26.09.2026: «только артисты») — просто по названию.
    final tracks = folder.tracks.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, size: 30),
          onPressed: () => setState(() => _openKey = null),
        ),
        title: Text(
          folder.display,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          // «Играть всё» / «Вперемешку» — крупные таблетки 56pt вместо текстовых
          // ссылок (разбор Gemini 26.09.2026): вслепую в машине.
          Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '${tracks.length} ${songWord(tracks.length)}',
              style: const TextStyle(color: Afisha.inkDim),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: _pill(
                    label: 'Играть всё',
                    icon: CupertinoIcons.play_fill,
                    accent: true,
                    onTap: tracks.isEmpty ? null : () => _playList(tracks, 0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _pill(
                    label: 'Вперемешку',
                    icon: CupertinoIcons.shuffle,
                    accent: false,
                    onTap: tracks.isEmpty ? null : () => _playList(tracks, 0, shuffle: true),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: Afisha.sep),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              itemCount: tracks.length,
              itemExtent: _kRowH,
              // Появление «лесенкой» — только у первых 12 строк и только один раз: в ленивом списке
              // строка пересоздаётся при прокрутке, и каждая заново «проявлялась» 0,4–0,8 с — список
              // мигал и казался пустым (ревизия кода 27.09.2026).
              itemBuilder: (_, i) => (i < 12 && _staggered.add(i))
                  ? _StaggerIn(index: i, child: _songRow(tracks, i))
                  : _songRow(tracks, i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required String label,
    required IconData icon,
    required bool accent,
    required VoidCallback? onTap,
  }) => _PressRow(
    onTap: onTap ?? () {},
    radius: 28,
    child: Container(
      height: 56,
      decoration: BoxDecoration(
        color: accent ? Afisha.lime : Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: accent ? Colors.black : Afisha.ink),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: accent ? Colors.black : Afisha.ink,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _songRow(List<DownloadedTrack> tracks, int i) {
    final t = tracks[i];
    // Было «320k · MP3 · 3:45 · 7.7 МБ» (Alex TG 18704); 26.09.2026 по разбору
    // Gemini Alex решил убрать технические данные («7 делай») — только длина.
    // Альбома на телефоне в базе нет, поэтому без «Альбом ·».
    final d = t.durationSec;
    final dur = d == null || d <= 0 ? '' : '${d ~/ 60}:${(d % 60).toString().padLeft(2, '0')}';
    // Только длительность: альбомы в плеере не нужны (Alex TG 21750, 26.09.2026).
    final spec = dur;
    return _rowShell(
      onTap: () => _playList(tracks, i),
      leading: CoverThumb(
        path: t.coverPath,
        url: coverUrlFor(t.id),
        size: 56,
        radius: 12,
        label: primaryArtist(t.artist),
      ),
      title: t.title,
      subtitle: spec,
      trailing: _songActions(t),
    );
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _onlyFav
                ? 'В избранном пока пусто'
                : 'На телефоне пока пусто.\nПесни для телефона отмечаются в '
                      'программе на компьютере — когда что-то появится, здесь '
                      'будет кнопка «Скачать».',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Afisha.inkDim, height: 1.5),
          ),
        ],
      ),
    ),
  );
}

/// Строка/кнопка, которая при касании подсвечивается (8% белого) и чуть
/// проседает (98%), отпустил — пружинит назад (разбор Gemini 26.09.2026).
class _PressRow extends StatefulWidget {
  const _PressRow({required this.onTap, required this.child, this.radius = 0});

  final VoidCallback onTap;
  final Widget child;
  final double radius;

  @override
  State<_PressRow> createState() => _PressRowState();
}

class _PressRowState extends State<_PressRow> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.98 : 1.0,
        duration: Duration(milliseconds: _down ? 80 : 350),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: BoxDecoration(
            color: _down ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Строки страницы исполнителя выплывают снизу каскадом: сдвиг 20pt, 400 мс,
/// задержка 30 мс между строками (только первые ~12 — дальше без задержки).
class _StaggerIn extends StatefulWidget {
  const _StaggerIn({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    final i = widget.index.clamp(0, 12);
    _delay = Timer(Duration(milliseconds: 30 * i), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: a,
      child: widget.child,
      builder: (_, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(offset: Offset(0, 20 * (1 - a.value)), child: child),
      ),
    );
  }
}

/// Папка «Имя не читается» — в самом конце списка (раздел «#»), как любой исполнитель.
class _BrokenFolder extends ArtistFolder {
  _BrokenFolder(List<DownloadedTrack> tracks) : super('_broken', 'Имя не читается', tracks);

  @override
  late final String letter = '#';
}

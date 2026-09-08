import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/player_controller.dart';
import 'artist_grouping.dart';

/// «Моя музыка» — вариант «Полка» (Alex 06.09.2026): сначала список
/// исполнителей (обложка + сколько песен), тап — его песни. 5000 песен
/// сворачиваются в несколько сотен строк, до нужного добраться реально.
///
/// Разные написания одного исполнителя («9 грамм», «9 Грамм»,
/// «9 грамм, Artizio», «9 Грамм feat. Miyagi») собираются в одну «папку» —
/// см. artist_grouping.dart (Alex TG 18687). Песни с нечитаемым именем —
/// в секцию «Имя не читается» сверху (Alex TG 18688).
class MyMusicScreen extends ConsumerStatefulWidget {
  const MyMusicScreen({super.key});

  @override
  ConsumerState<MyMusicScreen> createState() => _MyMusicScreenState();
}

class _MyMusicScreenState extends ConsumerState<MyMusicScreen> {
  bool _onlyFav = false;
  List<DownloadedTrack>? _items;
  List<ArtistFolder> _folders = const [];
  List<DownloadedTrack> _broken = const [];
  int _count = 0;
  int _bytes = 0;

  /// Ключ открытой папки исполнителя — null, если показываем список.
  String? _openKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _refresh();
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

    final s = await d.summary();
    final g = groupArtists(items);
    if (!mounted) return;
    setState(() {
      _items = items;
      _folders = g.folders;
      _broken = g.broken;
      _count = s.count;
      _bytes = s.bytes;
      // папка могла остаться без песен (всё удалили) — вернуться к списку
      if (_openKey != null && !_folders.any((f) => f.key == _openKey)) {
        _openKey = null;
      }
    });
  }

  String _mb(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
  }

  /// Обложка исполнителя — первая из его песен, что реально лежит на диске.
  String? _artistCover(List<DownloadedTrack> tracks) {
    for (final t in tracks) {
      final p = t.coverPath;
      if (p != null && p.isNotEmpty && File(p).existsSync()) return p;
    }
    return null;
  }

  Future<void> _playList(List<DownloadedTrack> list, int startIndex,
      {bool shuffle = false}) async {
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
    await ref.read(playerProvider).playQueue(queue,
        startIndex: startIndex < 0 ? 0 : startIndex, shuffle: shuffle);
  }

  Future<void> _toggleFav(DownloadedTrack t) async {
    await ref.read(downloadsProvider).setFavorite(t.id, !t.favorite);
    await _refresh();
  }

  Future<bool> _confirm(String title, String body, String okLabel) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(okLabel)),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _deleteTrack(DownloadedTrack t) async {
    final d = ref.read(downloadsProvider);
    if (!await _confirm('Удалить «${t.title}»?',
        'Файл сотрётся с телефона. Скачать заново можно будет с сервера.',
        'Удалить')) {
      return;
    }
    await d.delete(t.id);
    await _refresh();
  }

  Future<void> _wrongVersion(DownloadedTrack t) async {
    final d = ref.read(downloadsProvider);
    if (!await _confirm('Не та версия?',
        '«${t.title}» удалится, сервер потом подтянет другую версию.',
        'Убрать')) {
      return;
    }
    await d.delete(t.id, reason: 'wrong_version');
    await _refresh();
  }

  Future<void> _deleteArtist(ArtistFolder folder) async {
    final d = ref.read(downloadsProvider);
    if (!await _confirm('Удалить всего исполнителя?',
        '«${folder.display}» — ${folder.count} ${_songWord(folder.count)}. '
            'Все файлы сотрутся с телефона. Скачать заново можно с сервера.',
        'Удалить всё')) {
      return;
    }
    for (final t in folder.tracks) {
      await d.delete(t.id);
    }
    if (mounted) setState(() => _openKey = null);
    await _refresh();
  }

  // ─── битые имена ───────────────────────────────────────────────────────
  Future<void> _fixName(DownloadedTrack t) async {
    final artistCtl = TextEditingController(
        text: isBrokenName(t.artist) ? '' : t.artist);
    final titleCtl = TextEditingController(
        text: isBrokenName(t.title) ? '' : t.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Исправить имя'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: artistCtl,
              decoration: const InputDecoration(labelText: 'Исполнитель'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtl,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return;
    final artist = artistCtl.text.trim();
    final title = titleCtl.text.trim();
    if (artist.isEmpty || title.isEmpty) return;
    await ref.read(downloadsProvider).rename(t.id, artist: artist, title: title);
    await _refresh();
  }

  Future<void> _deleteBroken(DownloadedTrack t) async {
    if (!await _confirm('Удалить эту песню?',
        'Имя не читается, восстановить неоткуда. Файл сотрётся с телефона.',
        'Удалить')) {
      return;
    }
    await ref.read(downloadsProvider).delete(t.id, reason: 'broken_tag');
    await _refresh();
  }

  String _songWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'песня';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return 'песни';
    return 'песен';
  }

  @override
  Widget build(BuildContext context) {
    final key = _openKey;
    if (key == null) return _artistList();
    final folder = _folders.firstWhere(
      (f) => f.key == key,
      orElse: () => ArtistFolder(key, key, const []),
    );
    return _artistDetail(folder);
  }

  // ─── список: исполнители с 2+ песнями — папкой, с одной — прямо строкой
  //     песни (Alex 08.09.2026: «зачем по папкам по одной песне?»). ─────────
  Widget _artistList() {
    final hasBroken = _broken.isNotEmpty;
    final rowCount = _folders.length + (hasBroken ? 1 : 0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Моя музыка'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            // Строка-итог отдельной строкой над переключателем: с широким Inter
            // она не влезала в один ряд с кнопками и обрезалась (06.09.2026).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _onlyFav
                      ? '${_folders.length} ${_artistWord(_folders.length)} · '
                          '${_items?.length ?? 0} ${_songWord(_items?.length ?? 0)}'
                      : '${_folders.length} ${_artistWord(_folders.length)} · '
                          '$_count ${_songWord(_count)} · ${_mb(_bytes)}',
                  style: const TextStyle(color: Afisha.inkDim, fontSize: 12.5),
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Все')),
                    ButtonSegment(value: true, label: Text('Избранное')),
                  ],
                  selected: {_onlyFav},
                  onSelectionChanged: (s) {
                    setState(() => _onlyFav = s.first);
                    _refresh();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Afisha.line),
          Expanded(
            child: _items == null
                ? const Center(child: CircularProgressIndicator())
                : (_folders.isEmpty && !hasBroken)
                    ? _empty()
                    : ListView.separated(
                        itemCount: rowCount,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Afisha.line),
                        itemBuilder: (_, i) {
                          if (hasBroken && i == 0) return _brokenSection();
                          final f = _folders[i - (hasBroken ? 1 : 0)];
                          // Один трек у исполнителя — показываем сам трек, без
                          // «папки» на одну песню.
                          return f.tracks.length == 1
                              ? _soloTrackRow(f.tracks.first)
                              : _artistRow(f);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  /// Строка одиночной песни в списке исполнителей: обложка, «Название —
  /// Исполнитель», сердечко и меню. Тап — играть её.
  Widget _soloTrackRow(DownloadedTrack t) => ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: CoverThumb(
          path: t.coverPath,
          url: coverUrlFor(t.id),
          size: 46,
          radius: 23,
        ),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(t.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
        onTap: () => _playList([t], 0),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => _toggleFav(t),
              icon: Icon(
                t.favorite ? Icons.favorite : Icons.favorite_border,
                color: t.favorite ? Afisha.lime : Afisha.inkDim,
                size: 22,
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Afisha.inkDim),
              onSelected: (v) {
                switch (v) {
                  case 'fav':
                    _toggleFav(t);
                  case 'wrong':
                    _wrongVersion(t);
                  case 'delete':
                    _deleteTrack(t);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'fav',
                  child: Text(
                      t.favorite ? 'Убрать из избранного' : 'В избранное'),
                ),
                const PopupMenuItem(value: 'wrong', child: Text('Не та версия')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить песню')),
              ],
            ),
          ],
        ),
      );

  Widget _brokenSection() => Container(
        color: Afisha.surfaceHi,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.report_gmailerrorred,
                    color: Afisha.inkDim, size: 18),
                const SizedBox(width: 6),
                Text('Имя не читается — ${_broken.length} ${_songWord(_broken.length)}',
                    style: const TextStyle(
                        color: Afisha.inkDim,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            for (final t in _broken)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isBrokenName(t.title)
                                ? '(название не читается)'
                                : t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          Text(
                            t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Afisha.inkDim, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                        onPressed: () => _fixName(t),
                        child: const Text('Исправить имя')),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _deleteBroken(t),
                      icon: const Icon(Icons.delete_outline,
                          color: Afisha.inkDim, size: 20),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _artistRow(ArtistFolder f) => ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: CoverThumb(
          path: _artistCover(f.tracks),
          url: f.tracks.isNotEmpty ? coverUrlFor(f.tracks.first.id) : null,
          size: 46,
          radius: 23,
        ),
        title: Text(f.display, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${f.count} ${_songWord(f.count)}',
            style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
        onTap: () => setState(() => _openKey = f.key),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Afisha.inkDim),
          onSelected: (v) {
            switch (v) {
              case 'play':
                _playList(f.tracks, 0);
              case 'shuffle':
                _playList(f.tracks, 0, shuffle: true);
              case 'delete':
                _deleteArtist(f);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'play', child: Text('Играть всё')),
            PopupMenuItem(value: 'shuffle', child: Text('Вперемешку')),
            PopupMenuItem(
                value: 'delete', child: Text('Удалить всего исполнителя')),
          ],
        ),
      );

  // ─── песни одной папки исполнителя ─────────────────────────────────────
  Widget _artistDetail(ArtistFolder folder) {
    final tracks = folder.tracks.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _openKey = null),
        ),
        title: Text(folder.display, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text('${tracks.length} ${_songWord(tracks.length)}',
                    style: const TextStyle(color: Afisha.inkDim)),
                const Spacer(),
                TextButton.icon(
                  onPressed:
                      tracks.isEmpty ? null : () => _playList(tracks, 0),
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('Играть всё'),
                  style: TextButton.styleFrom(foregroundColor: Afisha.lime),
                ),
                TextButton.icon(
                  onPressed: tracks.isEmpty
                      ? null
                      : () => _playList(tracks, 0, shuffle: true),
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Вперемешку'),
                  style: TextButton.styleFrom(foregroundColor: Afisha.inkDim),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Afisha.line),
          Expanded(
            child: ListView.separated(
              itemCount: tracks.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Afisha.line),
              itemBuilder: (_, i) => _songRow(tracks, i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _songRow(List<DownloadedTrack> tracks, int i) {
    final t = tracks[i];
    // Одна строка характеристик: «320k · MP3 · 3:45 · 7.7 МБ». Совместки в
    // строку не выносим (Alex TG 18714) — полное написание видно в теге.
    final spec = [if (t.specs.isNotEmpty) t.specs, _mb(t.bytes)].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: CoverThumb(
          path: t.coverPath, url: coverUrlFor(t.id), size: 44),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(spec,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Afisha.inkDim, fontSize: 11.5)),
      onTap: () => _playList(tracks, i),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _toggleFav(t),
            icon: Icon(
              t.favorite ? Icons.favorite : Icons.favorite_border,
              color: t.favorite ? Afisha.lime : Afisha.inkDim,
              size: 22,
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Afisha.inkDim),
            onSelected: (v) {
              switch (v) {
                case 'fav':
                  _toggleFav(t);
                case 'wrong':
                  _wrongVersion(t);
                case 'delete':
                  _deleteTrack(t);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'fav',
                child: Text(t.favorite
                    ? 'Убрать из избранного'
                    : 'В избранное'),
              ),
              const PopupMenuItem(
                  value: 'wrong', child: Text('Не та версия')),
              const PopupMenuItem(
                  value: 'delete', child: Text('Удалить песню')),
            ],
          ),
        ],
      ),
    );
  }

  String _artistWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'исполнитель';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) {
      return 'исполнителя';
    }
    return 'исполнителей';
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
              _onlyFav
                  ? 'В избранном пока пусто'
                  : 'Пока ничего не скачано.\nОткрой «Библиотеку» и нажми «Докачать ещё».',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Afisha.inkDim, height: 1.5)),
        ),
      );
}

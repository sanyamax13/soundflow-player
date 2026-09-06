import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/config.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../player/player_controller.dart';
import '../search/search_screen.dart';

/// «Моя музыка» — вариант «Полка» (Alex 06.09.2026): сначала список
/// исполнителей (обложка + сколько песен), тап — его песни. 5000 песен
/// сворачиваются в несколько сотен строк, до нужного добраться реально.
/// Действия: удалить всего исполнителя, удалить песню, в избранное,
/// «не та версия». Меню — на «трёх точках» у строки.
class MyMusicScreen extends StatefulWidget {
  const MyMusicScreen({super.key});

  @override
  State<MyMusicScreen> createState() => _MyMusicScreenState();
}

class _MyMusicScreenState extends State<MyMusicScreen> {
  bool _onlyFav = false;
  List<DownloadedTrack>? _items;
  int _count = 0;
  int _bytes = 0;

  /// Открытый исполнитель — null, если показываем список исполнителей.
  String? _openArtist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _refresh();
  }

  Future<void> _refresh() async {
    final d = AppScope.of(context).downloads;
    final items = await d.list(onlyFavorite: _onlyFav);
    final s = await d.summary();
    if (!mounted) return;
    setState(() {
      _items = items;
      _count = s.count;
      _bytes = s.bytes;
      // исполнитель мог остаться без песен (всё удалили) — вернуться к списку
      if (_openArtist != null &&
          !items.any((t) => t.artist == _openArtist)) {
        _openArtist = null;
      }
    });
  }

  String _mb(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
  }

  /// Список -> Map «исполнитель -> его песни», исполнители по алфавиту.
  Map<String, List<DownloadedTrack>> get _byArtist {
    final map = <String, List<DownloadedTrack>>{};
    for (final t in _items ?? const <DownloadedTrack>[]) {
      (map[t.artist] ??= []).add(t);
    }
    final sorted = map.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {for (final k in sorted) k: map[k]!};
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
    await AppScope.of(context).player.playQueue(queue,
        startIndex: startIndex < 0 ? 0 : startIndex, shuffle: shuffle);
  }

  Future<void> _toggleFav(DownloadedTrack t) async {
    await AppScope.of(context).downloads.setFavorite(t.id, !t.favorite);
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
    final d = AppScope.of(context).downloads;
    if (!await _confirm('Удалить «${t.title}»?',
        'Файл сотрётся с телефона. Скачать заново можно будет с сервера.',
        'Удалить')) {
      return;
    }
    await d.delete(t.id);
    await _refresh();
  }

  Future<void> _wrongVersion(DownloadedTrack t) async {
    final d = AppScope.of(context).downloads;
    if (!await _confirm('Не та версия?',
        '«${t.title}» удалится, сервер потом подтянет другую версию.',
        'Убрать')) {
      return;
    }
    await d.delete(t.id, reason: 'wrong_version');
    await _refresh();
  }

  Future<void> _deleteArtist(String artist, List<DownloadedTrack> tracks) async {
    final d = AppScope.of(context).downloads;
    if (!await _confirm('Удалить всего исполнителя?',
        '«$artist» — ${tracks.length} ${_songWord(tracks.length)}. '
            'Все файлы сотрутся с телефона. Скачать заново можно с сервера.',
        'Удалить всё')) {
      return;
    }
    for (final t in tracks) {
      await d.delete(t.id);
    }
    if (mounted) setState(() => _openArtist = null);
    await _refresh();
  }

  String _songWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'песня';
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return 'песни';
    return 'песен';
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return _openArtist == null ? _artistList() : _artistDetail(_openArtist!);
  }

  // ─── список исполнителей ────────────────────────────────────────────────
  Widget _artistList() {
    final groups = _byArtist;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Моя музыка'),
        actions: [
          IconButton(onPressed: _openSearch, icon: const Icon(Icons.add)),
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
                  '${groups.length} ${_artistWord(groups.length)} · '
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
                : groups.isEmpty
                    ? _empty()
                    : ListView.separated(
                        itemCount: groups.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Afisha.line),
                        itemBuilder: (_, i) {
                          final artist = groups.keys.elementAt(i);
                          final tracks = groups[artist]!;
                          return _artistRow(artist, tracks);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _artistRow(String artist, List<DownloadedTrack> tracks) => ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: CoverThumb(
          path: _artistCover(tracks),
          url: tracks.isNotEmpty ? coverUrlFor(tracks.first.id) : null,
          size: 46,
          radius: 23,
        ),
        title: Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${tracks.length} ${_songWord(tracks.length)}',
            style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
        onTap: () => setState(() => _openArtist = artist),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Afisha.inkDim),
          onSelected: (v) {
            switch (v) {
              case 'play':
                _playList(tracks, 0);
              case 'shuffle':
                _playList(tracks, 0, shuffle: true);
              case 'delete':
                _deleteArtist(artist, tracks);
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

  // ─── песни одного исполнителя ──────────────────────────────────────────
  Widget _artistDetail(String artist) {
    final tracks = (_items ?? const <DownloadedTrack>[])
        .where((t) => t.artist == artist)
        .toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _openArtist = null),
        ),
        title: Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: CoverThumb(
          path: t.coverPath, url: coverUrlFor(t.id), size: 44),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_mb(t.bytes),
          style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                _onlyFav
                    ? 'В избранном пока пусто'
                    : 'Пока ничего не скачано',
                style: const TextStyle(color: Afisha.inkDim)),
            const SizedBox(height: 12),
            if (!_onlyFav)
              FilledButton(
                  onPressed: _openSearch,
                  child: const Text('Найти музыку')),
          ],
        ),
      );
}

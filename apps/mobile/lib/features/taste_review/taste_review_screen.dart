import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../app/providers.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';
import '../../data/api.dart';

/// «Разбор коллекции» (Alex TG 25.09.2026: «пройдись по всем песням,
/// подскажи, что моё, что нет»). Проверка на реальных данных показала:
/// жёсткую метку «не моё» ставить нечестно (звук почти не отличает
/// нравится/не нравится — 61-62% точности, история забракованных
/// исполнителей покрывает единицы треков, фидбек есть только у 8%
/// каталога) — см. память taste-playlists-request-2026-09-25. Поэтому не
/// три корзины, а ОДИН список для прослушивания, отсортированный от
/// «меньше похоже на твой вкус» к «больше» — Alex сам решает на слух,
/// порядок только ускоряет разбор большой коллекции (11+ тысяч песен).
/// Список сам актуален всегда: новый скачанный сборник — уже нерешённые
/// песни, попадут в очередь при следующем открытии экрана, без отдельной
/// команды «пересчитать».
class TasteReviewScreen extends ConsumerStatefulWidget {
  const TasteReviewScreen({super.key});

  @override
  ConsumerState<TasteReviewScreen> createState() => _TasteReviewScreenState();
}

class _TasteReviewScreenState extends ConsumerState<TasteReviewScreen> {
  final _player = AudioPlayer();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  String? _playingId;
  bool _playingLoading = false;

  Api get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _load();
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        setState(() {
          _playingId = null;
          _playingLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _api.tasteReview();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Компьютер недоступен';
      });
    }
  }

  Future<void> _togglePlay(Map<String, dynamic> t) async {
    final id = '${t['id']}';
    if (_playingId == id) {
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _playingId = null;
        _playingLoading = false;
      });
      return;
    }
    setState(() {
      _playingId = id;
      _playingLoading = true;
    });
    // Предпрослушка — отдельный плеер; иначе перебивала бы мини-плеер внизу.
    unawaited(ref.read(playerProvider).pause());
    try {
      final url = _api.catalogFileUrl(id);
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url), headers: _api.relayHeaders.isEmpty ? null : _api.relayHeaders),
      );
      await _player.play();
      if (!mounted) return;
      setState(() => _playingLoading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _playingId = null;
        _playingLoading = false;
      });
      Notice.show('Не удалось послушать', kind: NoticeKind.warn);
    }
  }

  Future<void> _stopIfPlaying(String id) async {
    if (_playingId == id) {
      await _player.stop();
      if (mounted) setState(() => _playingId = null);
    }
  }

  Future<void> _keep(int index) async {
    final t = _items[index];
    final id = '${t['id']}';
    await _stopIfPlaying(id);
    setState(() => _items = [..._items]..removeAt(index));
    // Локально в очередь — уйдёт на сервер при обычной синхронизации, трек
    // больше не попадёт в этот список (см. TasteReviewQueue на сервере).
    await ref.read(syncProvider).record('like', trackId: id);
    if (!mounted) return;
    Notice.show('Оставлено', subtitle: '${t['artist']} — ${t['title']}', kind: NoticeKind.done);
  }

  Future<void> _delete(int index) async {
    final t = _items[index];
    final id = '${t['id']}';
    final artist = '${t['artist']}';
    final title = '${t['title']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить навсегда?'),
        content: Text('$artist — $title\n\nФайл сотрётся с компьютера. Вернуть будет нельзя.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _stopIfPlaying(id);
    setState(() => _items = [..._items]..removeAt(index));
    try {
      await _api.catalogDeleteForever([id]);
      if (!mounted) return;
      Notice.show('Удалено насовсем', subtitle: '$artist — $title', kind: NoticeKind.removed);
    } catch (_) {
      if (!mounted) return;
      Notice.show('Не удалилось — компьютер недоступен', kind: NoticeKind.warn);
      setState(() => _items = [..._items.take(index), t, ..._items.skip(index)]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Разбор коллекции'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(CupertinoIcons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_loading && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Осталось разобрать: ${_items.length}',
                  style: const TextStyle(color: Afisha.inkDim, fontSize: 13),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Разбирать пока нечего — либо всё уже решено,\nлибо программа ещё мало знает твой вкус.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Afisha.inkDim),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: _items.length,
                        itemBuilder: (context, i) => _ReviewRow(
                          track: _items[i],
                          playing: _playingId == '${_items[i]['id']}' && !_playingLoading,
                          loading: _playingId == '${_items[i]['id']}' && _playingLoading,
                          onPlay: () => _togglePlay(_items[i]),
                          onKeep: () => _keep(i),
                          onDelete: () => _delete(i),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.track,
    required this.playing,
    required this.loading,
    required this.onPlay,
    required this.onKeep,
    required this.onDelete,
  });

  final Map<String, dynamic> track;
  final bool playing;
  final bool loading;
  final VoidCallback onPlay;
  final VoidCallback onKeep;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final artist = '${track['artist'] ?? ''}';
    final title = '${track['title'] ?? ''}';
    final album = '${track['album'] ?? ''}';
    return ListTile(
      leading: IconButton(
        onPressed: loading ? null : onPlay,
        icon: loading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(playing ? CupertinoIcons.pause_circle_fill : CupertinoIcons.play_circle_fill, size: 30),
      ),
      title: Text('$artist — $title', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: album.isEmpty ? null : Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onKeep,
            icon: const Icon(CupertinoIcons.heart, color: Afisha.lime),
            tooltip: 'Оставить',
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(CupertinoIcons.trash, color: Colors.redAccent),
            tooltip: 'Удалить навсегда',
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
import '../../core/cover_thumb.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';
import '../../data/api.dart';

/// «Открытия» (Alex TG 24.09.2026: «сделай пункт меню открытия», «поиск
/// давай торрентам и яндексу») — то, что раньше было только в окне на
/// компьютере: подборка «Волны» по вкусу (Яндекс + торренты, см.
/// wave-torrents-plan) и песни по ссылке на плейлист Яндекс.Музыки. Теперь и
/// на телефоне, теми же ручками — работает и дома по Wi-Fi, и через
/// «Настройки → Удалённый доступ».
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _urlCtrl = TextEditingController();
  final _player = AudioPlayer();

  bool _loadingDays = true;
  List<Map<String, dynamic>> _days = const [];
  int _day = 0;

  bool _loadingList = true;
  List<Map<String, dynamic>> _items = const [];
  String? _error;

  // Режим «плейлист по ссылке» — включается после «Показать», выключается
  // «Закрыть» (возврат к «Волне»).
  bool _playlistMode = false;
  String? _playlistTitle;

  String? _playingKey; // artist|title того, что сейчас звучит/грузится
  bool _playingLoading = false;

  Api get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _loadDays();
    _loadWave();
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        setState(() {
          _playingKey = null;
          _playingLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  String _key(Map<String, dynamic> t) => '${t['artist']}|${t['title']}';

  Future<void> _loadDays() async {
    setState(() => _loadingDays = true);
    try {
      final days = await _api.waveDays();
      if (!mounted) return;
      setState(() {
        _days = days;
        _loadingDays = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingDays = false);
    }
  }

  Future<void> _loadWave({bool refresh = false}) async {
    setState(() {
      _loadingList = true;
      _error = null;
    });
    try {
      final items = await _api.wave(day: _day, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingList = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingList = false;
        _error = 'Компьютер недоступен';
      });
    }
  }

  Future<void> _showPlaylist() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loadingList = true;
      _error = null;
    });
    try {
      final r = await _api.yandexPlaylist(url);
      if (!mounted) return;
      setState(() {
        _playlistMode = true;
        _playlistTitle = r.title;
        _items = r.items;
        _loadingList = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingList = false;
        _error = e is AcquireException ? e.message : 'Не получилось открыть плейлист';
      });
    }
  }

  void _closePlaylist() {
    setState(() {
      _playlistMode = false;
      _playlistTitle = null;
      _urlCtrl.clear();
    });
    _loadWave();
  }

  Future<void> _selectDay(int day) async {
    if (day == _day) return;
    setState(() => _day = day);
    await _loadWave();
  }

  Future<void> _togglePlay(Map<String, dynamic> t) async {
    final key = _key(t);
    if (_playingKey == key) {
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _playingKey = null;
        _playingLoading = false;
      });
      return;
    }
    setState(() {
      _playingKey = key;
      _playingLoading = true;
    });
    try {
      final url = _api.discoverPreviewUrl(
        id: '${t['yandex_id'] ?? ''}',
        artist: '${t['artist'] ?? ''}',
        title: '${t['title'] ?? ''}',
      );
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(url), headers: _api.relayHeaders.isEmpty ? null : _api.relayHeaders),
      );
      await _player.play();
      if (!mounted) return;
      setState(() => _playingLoading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _playingKey = null;
        _playingLoading = false;
      });
      Notice.show('Не удалось послушать', kind: NoticeKind.warn);
    }
  }

  Future<void> _dismiss(int index) async {
    final t = _items[index];
    final artist = '${t['artist'] ?? ''}';
    final title = '${t['title'] ?? ''}';
    if (_playingKey == _key(t)) await _player.stop();
    setState(() {
      _items = [..._items]..removeAt(index);
      if (_playingKey == _key(t)) _playingKey = null;
    });
    try {
      await _api.discoverDismiss(artist, title);
    } catch (_) {
      // не критично — при следующей загрузке списка просто снова появится
    }
    if (!mounted) return;
    Notice.show(
      'Убрано',
      subtitle: '$artist — $title',
      kind: NoticeKind.removed,
      actions: [
        NoticeAction('Вернуть', () async {
          try {
            await _api.discoverUndismiss(artist, title);
          } catch (_) {}
          if (mounted) {
            setState(() => _items = [..._items.take(index), t, ..._items.skip(index)]);
          }
        }, primary: false),
      ],
    );
  }

  Future<void> _acquire(int index) async {
    final t = _items[index];
    final artist = '${t['artist'] ?? ''}';
    final title = '${t['title'] ?? ''}';
    try {
      await _api.discoverAcquire(artist, title);
      Notice.show('Скачивание запущено', subtitle: '$artist — $title', kind: NoticeKind.done);
    } catch (_) {
      Notice.show('Не получилось запустить скачивание', kind: NoticeKind.warn);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_playlistMode ? (_playlistTitle?.isNotEmpty == true ? _playlistTitle! : 'Плейлист') : 'Открытия'),
        actions: [
          if (_playlistMode)
            TextButton(onPressed: _closePlaylist, child: const Text('Закрыть'))
          else
            IconButton(
              onPressed: _loadingList ? null : () => _loadWave(refresh: _day == 0),
              icon: const Icon(CupertinoIcons.refresh),
              tooltip: 'Пересобрать волну',
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_playlistMode,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'Ссылка на плейлист Яндекс.Музыки',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _showPlaylist(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _playlistMode ? null : _showPlaylist,
                  child: const Text('Показать'),
                ),
              ],
            ),
          ),
          if (!_playlistMode && !_loadingDays && _days.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: AppleSegmented<int>(
                options: {
                  for (final d in _days)
                    (d['day'] as num).toInt(): '${d['label']}',
                },
                selected: _day,
                onChanged: _selectDay,
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          Expanded(
            child: _loadingList
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Text(
                          _playlistMode ? 'В плейлисте пусто' : 'Пока ничего нового не нашлось',
                          style: const TextStyle(color: Afisha.inkDim),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: _items.length,
                        itemBuilder: (context, i) => _DiscoverRow(
                          track: _items[i],
                          playing: _playingKey == _key(_items[i]) && !_playingLoading,
                          loading: _playingKey == _key(_items[i]) && _playingLoading,
                          onPlay: () => _togglePlay(_items[i]),
                          onAcquire: () => _acquire(i),
                          onDismiss: () => _dismiss(i),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _DiscoverRow extends StatelessWidget {
  const _DiscoverRow({
    required this.track,
    required this.playing,
    required this.loading,
    required this.onPlay,
    required this.onAcquire,
    required this.onDismiss,
  });

  final Map<String, dynamic> track;
  final bool playing;
  final bool loading;
  final VoidCallback onPlay;
  final VoidCallback onAcquire;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final artist = '${track['artist'] ?? ''}';
    final title = '${track['title'] ?? ''}';
    final album = '${track['album'] ?? ''}';
    final haveIt = track['already_have'] == true;
    return ListTile(
      leading: CoverThumb(url: '${track['cover_url'] ?? ''}', label: artist),
      title: Text('$artist — $title', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: album.isEmpty ? null : Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: loading ? null : onPlay,
            icon: loading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill),
          ),
          if (haveIt)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.check_circle, color: Afisha.lime, size: 22),
            )
          else
            IconButton(
              onPressed: onAcquire,
              icon: const Icon(CupertinoIcons.cloud_download),
              tooltip: 'Скачать',
            ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(CupertinoIcons.xmark, size: 18),
            tooltip: 'Убрать',
          ),
        ],
      ),
    );
  }
}

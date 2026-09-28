import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:solar_icons/solar_icons.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
import '../../core/glass_sheet.dart';
import '../../core/cover_thumb.dart';
import '../../core/notice.dart';
import '../../core/staggered_entry.dart';
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

  // «Слушать всё» (Alex «да», 26.09.2026): песни играют подряд — кончилась одна, сама
  // начинается следующая. Для машины: слушаешь и скачиваешь понравившееся, ничего не тыкая.
  bool _playAll = false;

  // Прогресс «Скачать» (Alex TG 24.09.2026: «нет прогресс бара, качается ли,
  // что делает») — artist|title → состояние из /api/acquire/log. Опрашивается,
  // пока в этом словаре есть хоть одна «running» запись.
  final Map<String, ({String state, String note})> _acquireStatus = {};
  Timer? _pollTimer;

  Api get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _loadDays();
    _loadWave();
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        final finished = _playingKey;
        setState(() {
          _playingKey = null;
          _playingLoading = false;
        });
        if (_playAll) _playNextAfter(finished);
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _player.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _ensurePolling() {
    _pollTimer ??= Timer.periodic(const Duration(seconds: 3), (_) => _pollAcquireLog());
  }

  Future<void> _pollAcquireLog() async {
    List<Map<String, dynamic>> log;
    try {
      log = await _api.acquireLog();
    } catch (_) {
      return; // сеть моргнула — попробуем на следующем тике
    }
    if (!mounted) return;
    setState(() {
      for (final e in log) {
        final key = '${e['artist']}|${e['title']}';
        if (!_acquireStatus.containsKey(key)) continue; // не наша заявка — не мешаем
        _acquireStatus[key] = (state: '${e['state']}', note: '${e['note'] ?? ''}');
      }
    });
    // Ничего не качается — опрос больше не нужен, до следующего «Скачать».
    if (_acquireStatus.values.every((v) => v.state != 'running')) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
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

  /// Первый заход за сегодняшнюю волну (кэша ещё нет — до 6 утра, когда
  /// программа сама её соберёт) реально ищет по Яндексу и торрентам — не
  /// мгновенно (поймано вживую 24.09.2026: телефон Alex сдался ждать раньше,
  /// чем компьютер закончил — «Компьютер недоступен» на пустом месте, хотя
  /// компьютер всё это время был жив и доделал сам). [attempt] считает
  /// автопопытки при «уже собираю» (WaveBuildingException) — не более 5,
  /// чтобы не долбить компьютер бесконечно, если он и правда недоступен.
  Future<void> _loadWave({bool refresh = false, int attempt = 0}) async {
    setState(() => _loadingList = true);
    try {
      final items = await _api.wave(day: _day, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingList = false;
        _error = null;
      });
    } on WaveBuildingException {
      // Компьютер уже собирает волну прямо сейчас — не ошибка, ждём и
      // пробуем ещё раз сами, не заставляя Alex тыкать «обновить» вручную.
      if (!mounted) return;
      if (attempt >= 5) {
        setState(() {
          _loadingList = false;
          _error = 'Подборка долго собирается — попробуйте обновить позже';
        });
        return;
      }
      setState(() => _error = 'Компьютер собирает подборку — подождите…');
      await Future.delayed(const Duration(seconds: 8));
      if (mounted) await _loadWave(attempt: attempt + 1);
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

  /// Шторка с полем ссылки в общем стеклянном виде (glass_sheet.dart). Если в буфере уже лежит
  /// ссылка Яндекс.Музыки — сверху большая кнопка «Добавить из буфера», вставлять руками не надо
  /// (разбор Алисы 27.09.2026). Нет — клавиатура открыта сразу, «Показать» — Enter или кнопка.
  Future<void> _askPlaylistLink() async {
    String? clip;
    try {
      // С ограничением по времени: буфер не должен задерживать саму шторку.
      final t = (await Clipboard.getData(Clipboard.kTextPlain).timeout(const Duration(milliseconds: 400)))?.text?.trim();
      if (t != null && t.contains('music.yandex')) clip = t;
    } catch (_) {}
    if (!mounted) return;
    final go = await showGlassSheet<bool>(
      context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const GlassSheetTitle('Плейлист Яндекс.Музыки',
                body: 'В Яндекс.Музыке: плейлист → «Поделиться» → скопировать ссылку'),
            if (clip != null) ...[
              GlassSheetButton(
                label: 'Добавить из буфера',
                kind: GlassButtonKind.lime,
                onTap: () {
                  _urlCtrl.text = clip!;
                  Navigator.pop(ctx, true);
                },
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _urlCtrl,
              autofocus: clip == null,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              style: const TextStyle(fontSize: 17),
              decoration: InputDecoration(
                hintText: 'https://music.yandex.ru/…',
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
            GlassSheetButton(
              label: 'Показать',
              kind: clip == null ? GlassButtonKind.lime : GlassButtonKind.plain,
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
    if (go == true && mounted) await _showPlaylist();
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
      _playAll = false; // остановил сам — «подряд» тоже выключаем
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
    // Предпрослушка — отдельный плеер (см. класс); если в мини-плеере уже
    // что-то играет, обе песни звучали бы разом без этой паузы.
    unawaited(ref.read(playerProvider).pause());
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

  /// Следующая после [key] песня списка (для «Слушать всё»); конец списка — стоп.
  void _playNextAfter(String? key) {
    final i = key == null ? -1 : _items.indexWhere((t) => _key(t) == key);
    if (i + 1 < _items.length) {
      unawaited(_togglePlay(_items[i + 1]));
    } else {
      setState(() => _playAll = false);
    }
  }

  Future<void> _toggleAll() async {
    if (_playAll) {
      setState(() => _playAll = false);
      await _player.stop();
      if (mounted) setState(() => _playingKey = null);
      return;
    }
    if (_items.isEmpty) return;
    setState(() => _playAll = true);
    final cur = _playingKey == null ? -1 : _items.indexWhere((t) => _key(t) == _playingKey);
    if (cur < 0) await _togglePlay(_items.first); // уже что-то играет — просто дальше пойдёт подряд
  }

  Future<void> _dismiss(int index) async {
    final t = _items[index];
    final artist = '${t['artist'] ?? ''}';
    final title = '${t['title'] ?? ''}';
    // Сначала убрать из списка (свайп требует, чтобы строка ушла сразу), потом остановить звук.
    final wasPlaying = _playingKey == _key(t);
    setState(() {
      _items = [..._items]..removeAt(index);
      if (wasPlaying) _playingKey = null;
    });
    if (wasPlaying) await _player.stop();
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
    final key = _key(t);
    setState(() => _acquireStatus[key] = (state: 'running', note: 'ищу…'));
    _ensurePolling();
    try {
      await _api.discoverAcquire(artist, title);
    } catch (_) {
      if (!mounted) return;
      setState(() => _acquireStatus[key] = (state: 'fail', note: 'не получилось запустить'));
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
          else ...[
            // Ссылка на плейлист нужна редко — под значком, а не полем на пол-экрана
            // (разбор Gemini 26.09.2026, «Открытия»).
            IconButton(
              onPressed: _askPlaylistLink,
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              icon: const Icon(SolarIconsOutline.link, color: Colors.white70),
              tooltip: 'Плейлист по ссылке',
            ),
            IconButton(
              onPressed: _loadingList ? null : () => _loadWave(refresh: _day == 0),
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              icon: Icon(SolarIconsOutline.refresh, color: _loadingList ? Colors.white24 : Colors.white70),
              tooltip: 'Пересобрать волну',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (!_playlistMode && !_loadingDays && _days.length > 1)
            Padding(
              // 8 → 16 снизу: в машине палец не должен цеплять соседнее (вердикт Gemini 26.09.2026)
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: AppleSegmented<int>(
                options: {
                  for (final d in _days)
                    (d['day'] as num).toInt(): '${d['label']}',
                },
                selected: _day,
                onChanged: _selectDay,
              ),
            ),
          if (!_loadingList && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                height: 56,
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _playAll ? Afisha.groupHi : Afisha.lime,
                    foregroundColor: _playAll ? Afisha.ink : Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  onPressed: _toggleAll,
                  icon: Icon(_playAll ? SolarIconsBold.stop : SolarIconsBold.play, size: 20),
                  label: Text(_playAll ? 'Остановить' : 'Слушать всё',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
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
                        itemBuilder: (context, i) => StaggeredEntry(
                          index: i,
                          // «Убрать» — свайпом влево (как в iOS), кнопки ✕ в строке больше нет;
                          // «Вернуть» — в плашке снизу (_dismiss).
                          child: Dismissible(
                            key: ValueKey('d-${_key(_items[i])}'),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) => _dismiss(i),
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 28),
                              color: Afisha.red,
                              child: const Icon(SolarIconsOutline.trashBinTrash, color: Colors.white, size: 26),
                            ),
                            child: _DiscoverRow(
                            track: _items[i],
                            playing: _playingKey == _key(_items[i]) && !_playingLoading,
                            loading: _playingKey == _key(_items[i]) && _playingLoading,
                            status: _acquireStatus[_key(_items[i])],
                            onPlay: () => _togglePlay(_items[i]),
                            onAcquire: () => _acquire(i),
                          ),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Строка «Открытий» (разбор Gemini 26.09.2026, Alex «беру»): название сверху, исполнитель снизу;
/// нажатие на строку — послушать/пауза; справа одна кнопка «скачать» (кружок пока качается,
/// галочка — есть); «убрать» — свайпом влево (см. Dismissible выше). Играющая — лаймом.
class _DiscoverRow extends StatelessWidget {
  const _DiscoverRow({
    required this.track,
    required this.playing,
    required this.loading,
    required this.status,
    required this.onPlay,
    required this.onAcquire,
  });

  final Map<String, dynamic> track;
  final bool playing;
  final bool loading;

  /// Прогресс «Скачать» для этой строки (null — ничего не запускали).
  final ({String state, String note})? status;

  final VoidCallback onPlay;
  final VoidCallback onAcquire;

  @override
  Widget build(BuildContext context) {
    final artist = '${track['artist'] ?? ''}';
    final title = '${track['title'] ?? ''}';
    final haveIt = track['already_have'] == true || status?.state == 'done';
    final s = status;
    final active = playing || loading;
    // Пока качается/если не вышло — вместо исполнителя что именно происходит
    // (Alex TG 24.09.2026: «нет прогресс бара, качается ли, что делает»).
    final sub = s != null && s.state != 'done'
        ? (s.note.isEmpty ? (s.state == 'running' ? 'качаю…' : 'не вышло') : s.note)
        : artist;
    final subColor = s != null && s.state == 'fail'
        ? Colors.redAccent
        : (s != null && s.state == 'running' ? Afisha.lime : Colors.white.withValues(alpha: 0.55));
    return InkWell(
      onTap: loading ? null : onPlay,
      child: SizedBox(
        height: 76,
        child: Row(
          children: [
            const SizedBox(width: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverThumb(url: '${track['cover_url'] ?? ''}', label: artist, size: 56, radius: 12),
                    if (active)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: 0.45),
                        child: Center(
                          child: loading
                              ? const SizedBox(
                                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Afisha.lime))
                              : const Icon(SolarIconsBold.volumeLoud, color: Afisha.lime, size: 24),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600, color: active ? Afisha.lime : Afisha.ink)),
                  const SizedBox(height: 2),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: subColor)),
                ],
              ),
            ),
            SizedBox(
              width: 64,
              height: 64,
              child: haveIt
                  ? const Icon(SolarIconsBold.checkCircle, color: Afisha.lime, size: 26)
                  : s?.state == 'running'
                      ? const Center(
                          child: SizedBox(
                              width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Afisha.lime)))
                      : IconButton(
                          onPressed: onAcquire,
                          icon: Icon(
                            // закрашенная — тонкий контур терялся на чёрном (вердикт Gemini 26.09.2026)
                            s?.state == 'fail' ? SolarIconsOutline.refresh : SolarIconsBold.cloudDownload,
                            color: s?.state == 'fail' ? Colors.redAccent : Colors.white.withValues(alpha: 0.8),
                            size: 26,
                          ),
                          tooltip: s?.state == 'fail' ? 'Попробовать снова' : 'Скачать',
                        ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

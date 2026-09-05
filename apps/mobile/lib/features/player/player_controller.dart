import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Обёртка над проигрывателем. Держит очередь локальных файлов (офлайн),
/// отдаёт наружу простые ValueNotifier'ы для UI. Фон/локскрин — через
/// `audio_service` (см. audio_handler.dart). Гэплесс, нормализация —
/// следующими шагами.
class PlayerController {
  PlayerController({this.onPlay, this.onSkip}) {
    _initSession();
  }

  // Пришло что-то поверх музыки (голосовое в мессенджере, звонок) и это
  // временно (не насовсем отдали фокус другому приложению) — запоминаем,
  // что играли, чтобы вернуть звук, когда прерывание закончится. Без этого
  // музыка просто остаётся на паузе навсегда — баг, который Alex поймал в
  // реальной жизни 05.09.2026 (дослушал голосовое, музыка не продолжилась).
  bool _resumeAfterInterruption = false;

  Future<void> _initSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _resumeAfterInterruption = playing.value &&
            (event.type == AudioInterruptionType.pause ||
                event.type == AudioInterruptionType.duck);
      } else if (_resumeAfterInterruption) {
        _resumeAfterInterruption = false;
        play();
      }
    });
  }

  /// Вызывается, когда трек начал играть (в т.ч. авто-переход к следующему) —
  /// сюда вешаем запись события «слушал».
  final void Function(NowPlaying meta)? onPlay;

  /// Вызывается, когда пользователь сам перескочил вперёд/назад — событие «пропуск».
  final void Function(NowPlaying meta)? onSkip;

  AudioPlayer? _player;
  List<NowPlaying> _queue = const [];
  int _index = 0;
  String? _lastPlayId;

  final ValueNotifier<NowPlaying?> now = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> shuffle = ValueNotifier(false);

  final _subs = <StreamSubscription<dynamic>>[];

  AudioPlayer _ensure() {
    final p = _player;
    if (p != null) return p;
    final np = AudioPlayer();
    _subs.add(np.playingStream.listen((v) => playing.value = v));
    _subs.add(np.positionStream.listen((v) => position.value = v));
    _subs.add(np.durationStream.listen((v) => duration.value = v ?? Duration.zero));
    _subs.add(np.currentIndexStream.listen((i) {
      if (i == null || i < 0 || i >= _queue.length) return;
      _index = i;
      final track = _queue[i];
      now.value = track;
      // Событие «слушал» — только на смену трека, а не на каждый повтор по кругу.
      if (track.id != _lastPlayId) {
        _lastPlayId = track.id;
        onPlay?.call(track);
      }
    }));
    _subs.add(np.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) playing.value = false;
    }));
    _player = np;
    return np;
  }

  /// Поставить очередь и начать играть с [startIndex].
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
  }) async {
    if (tracks.isEmpty) return;
    _queue = List.of(tracks);
    _index = startIndex.clamp(0, tracks.length - 1);
    _lastPlayId = null;
    final p = _ensure();
    final src = ConcatenatingAudioSource(
      children: [for (final t in _queue) AudioSource.uri(Uri.file(t.path))],
    );
    await p.setLoopMode(loop ? LoopMode.all : LoopMode.off);
    await p.setShuffleModeEnabled(shuffle);
    this.shuffle.value = shuffle;
    await p.setAudioSource(src, initialIndex: _index, initialPosition: Duration.zero);
    now.value = _queue[_index];
    // currentIndexStream отдаст этот же индекс и запишет play — второй раз тут не зовём.
    await p.play();
  }

  /// Один трек, без зацикливания (тап «играть» в «Моей музыке»).
  Future<void> playSingle(NowPlaying track) =>
      playQueue([track], startIndex: 0, loop: false);

  Future<void> next() async {
    final p = _player;
    if (p == null) return;
    onSkip?.call(now.value ?? _queue[_index]);
    await p.seekToNext();
  }

  Future<void> prev() async {
    final p = _player;
    if (p == null) return;
    // Первые секунды — «в начало трека», дальше — предыдущий.
    if (p.position > const Duration(seconds: 3)) {
      await p.seek(Duration.zero);
      return;
    }
    onSkip?.call(now.value ?? _queue[_index]);
    await p.seekToPrevious();
  }

  Future<void> seek(Duration to) async => _player?.seek(to);

  Future<void> toggleShuffle() async {
    final p = _player;
    if (p == null) return;
    final v = !shuffle.value;
    await p.setShuffleModeEnabled(v);
    shuffle.value = v;
  }

  /// Строго "играть" (не переключатель) — нужно внешнему управлению
  /// (Bluetooth-магнитола, наушники, экран блокировки — см. audio_handler.dart,
  /// 05.09.2026), которое присылает раздельные команды play/pause, а не тап
  /// по одной кнопке.
  Future<void> play() async => _player?.play();

  /// Строго "пауза" — см. play().
  Future<void> pause() async => _player?.pause();

  Future<void> toggle() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _player?.dispose();
  }
}

class NowPlaying {
  const NowPlaying({
    required this.id,
    required this.title,
    required this.artist,
    this.path = '',
    this.coverPath,
  });
  final String id;
  final String title;
  final String artist;
  final String path;
  final String? coverPath; // локальный файл обложки на телефоне; null — нет
}

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/crash_log.dart';

/// Обёртка над проигрывателем. Держит очередь локальных файлов (офлайн),
/// отдаёт наружу простые ValueNotifier'ы для UI. Фон/локскрин — через
/// `audio_service` (см. audio_handler.dart). Гэплесс, нормализация —
/// следующими шагами.
class PlayerController {
  PlayerController({this.onPlay, this.onSkip, this.onComplete, this.onDuration}) {
    _initSession();
  }

  // true между вызовом next/prev/jumpTo и приходом нового индекса — чтобы
  // авто-переход (трек доиграл) не спутать с ручным перескоком.
  bool _userSeek = false;
  int _prevIndex = -1;

  // Пришло что-то поверх музыки (голосовое в мессенджере, звонок) и это
  // временно (не насовсем отдали фокус другому приложению) — запоминаем,
  // что играли, чтобы вернуть звук, когда прерывание закончится. Без этого
  // музыка просто остаётся на паузе навсегда — баг, который Alex поймал в
  // реальной жизни 05.09.2026 (дослушал голосовое, музыка не продолжилась).
  bool _resumeAfterInterruption = false;

  Future<void> _initSession() async {
    try {
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
    } catch (_) {
      // Нет плагина аудиосессии (виджет-тест / рендер макета) — не критично.
    }
  }

  /// Вызывается, когда трек начал играть (в т.ч. авто-переход к следующему) —
  /// сюда вешаем запись события «слушал».
  final void Function(NowPlaying meta)? onPlay;

  /// Пользователь сам перескочил вперёд/назад — событие «пропуск». Отдаём
  /// позицию и длительность: сервер по ним отличает «бросил сразу» от
  /// «дослушал почти до конца» (обучение вкусу, TASTE-PLAN §1).
  final void Function(NowPlaying meta, Duration position, Duration total)? onSkip;

  /// Трек доиграл сам до конца (не перескок) — событие «дослушал».
  final void Function(NowPlaying meta)? onComplete;

  /// Плеер узнал длительность играющего файла — повод записать её (и оценку
  /// битрейта) в «Мою музыку», если там ещё нет (Alex TG 18704).
  final void Function(String trackId, Duration total)? onDuration;

  AudioPlayer? _player;
  ConcatenatingAudioSource? _source;
  List<NowPlaying> _queue = const [];
  int _index = 0;
  String? _lastPlayId;

  final ValueNotifier<NowPlaying?> now = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> shuffle = ValueNotifier(false);

  /// «Радио по этой песне» активно — хвост очереди выстроен по близости
  /// звучания к той песне, с которой радио запустили (06.09.2026).
  final ValueNotifier<bool> radio = ValueNotifier(false);

  final _subs = <StreamSubscription<dynamic>>[];

  // Битый/недоступный файл в очереди раньше выбрасывал необработанную ошибку
  // из потока событий just_audio — и на некоторых телефонах падало всё
  // приложение (Alex TG 19028: «слушаю через колонку, разные песни, плеер
  // просто закрывается»). Теперь ошибку ловим: перескок на следующий трек,
  // приложение живо. Счётчик подряд — чтобы не крутиться вечно по битым.
  int _consecutiveErrors = 0;
  DateTime _lastErrorAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _onPlaybackError(Object e, StackTrace st) {
    CrashLog.write(e, st, where: 'player');
    final now = DateTime.now();
    if (now.difference(_lastErrorAt) > const Duration(seconds: 10)) {
      _consecutiveErrors = 0;
    }
    _lastErrorAt = now;
    _consecutiveErrors++;

    // Реакцию (pause/seekToNext) НЕЛЬЗЯ звать прямо здесь: этот колбэк —
    // синхронная рассылка ошибки из потока just_audio, а pause()/seekToNext()
    // пишут в те же rxdart-Subject внутри плеера → «Bad state: Cannot fire
    // new event. Controller is already firing an event» и падение ВСЕГО
    // приложения (Alex 08.09.2026, поймано чёрным ящиком, стек упирался в
    // AudioPlayer.pause ← _onPlaybackError). Откладываем на микротаск —
    // отработает, когда поток закончил слать событие.
    scheduleMicrotask(() {
      final p = _player;
      if (p == null) return;
      if (_consecutiveErrors > 5) {
        // Похоже, беда не в одном файле — не долбим дальше, просто встаём.
        p.pause().catchError((_) {});
        return;
      }
      if (_queue.length > 1) {
        p.seekToNext().catchError((_) {});
      } else {
        p.pause().catchError((_) {});
      }
    });
  }

  AudioPlayer _ensure() {
    final p = _player;
    if (p != null) return p;
    final np = AudioPlayer();
    _subs.add(np.playbackEventStream.listen((_) {}, onError: _onPlaybackError));
    _subs.add(np.playingStream.listen((v) {
      playing.value = v;
      // Событие «слушал» — по факту начала воспроизведения (в т.ч. первый
      // play по заряженной на паузе очереди «Потока»). Дедуп по _lastPlayId.
      if (v) {
        final t = now.value;
        if (t != null && t.id != _lastPlayId) {
          _lastPlayId = t.id;
          onPlay?.call(t);
        }
      }
    }));
    _subs.add(np.positionStream.listen((v) => position.value = v));
    _subs.add(np.durationStream.listen((v) {
      duration.value = v ?? Duration.zero;
      final id = now.value?.id;
      if (v != null && v > Duration.zero && id != null) onDuration?.call(id, v);
    }));
    _subs.add(np.currentIndexStream.listen((i) {
      if (i == null || i < 0 || i >= _queue.length) return;
      // Индекс сменился сам (не перескоком) → предыдущий трек доиграл до конца.
      if (i != _prevIndex && _prevIndex >= 0 && _prevIndex < _queue.length) {
        if (!_userSeek) onComplete?.call(_queue[_prevIndex]);
      }
      _userSeek = false;
      _prevIndex = i;
      _index = i;
      final track = _queue[i];
      now.value = track;
      // Авто-переход к следующему во время игры — тоже «слушал». На паузе
      // (зарядка очереди «Потока») не пишем — это сделает playingStream по
      // нажатию play. Дедуп по _lastPlayId.
      if (track.id != _lastPlayId && (_player?.playing ?? false)) {
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

  /// Поставить очередь и начать играть с [startIndex]. [autoplay] = false —
  /// только зарядить очередь (плеер на паузе): вкладка «Поток» так показывает
  /// полный плеер с обложкой и кнопками ещё до нажатия play.
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) async {
    if (tracks.isEmpty) return;
    _queue = List.of(tracks);
    _index = startIndex.clamp(0, tracks.length - 1);
    _prevIndex = _index; // новая очередь — не считаем сменой трека
    _userSeek = false;
    _lastPlayId = null;
    _consecutiveErrors = 0;
    radio.value = false;
    final p = _ensure();
    final src = ConcatenatingAudioSource(
      children: [for (final t in _queue) AudioSource.uri(Uri.file(t.path))],
    );
    _source = src;
    try {
      await p.setLoopMode(loop ? LoopMode.all : LoopMode.off);
      await p.setShuffleModeEnabled(shuffle);
      this.shuffle.value = shuffle;
      await p.setAudioSource(src, initialIndex: _index, initialPosition: Duration.zero);
      now.value = _queue[_index];
      // currentIndexStream отдаст этот же индекс и запишет play — второй раз тут не зовём.
      if (autoplay) await p.play();
    } catch (e, st) {
      // Не роняем экран, с которого запустили: пишем в чёрный ящик, дальше
      // авто-перескок по битым разрулит _onPlaybackError.
      CrashLog.write(e, st, where: 'playQueue');
    }
  }

  /// Один трек, без зацикливания (тап «играть» в «Моей музыке»).
  Future<void> playSingle(NowPlaying track) =>
      playQueue([track], startIndex: 0, loop: false);

  void _reportSkip() {
    final p = _player;
    _userSeek = true;
    onSkip?.call(now.value ?? _queue[_index],
        p?.position ?? Duration.zero, p?.duration ?? Duration.zero);
  }

  Future<void> next() async {
    final p = _player;
    if (p == null) return;
    _reportSkip();
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
    _reportSkip();
    await p.seekToPrevious();
  }

  Future<void> seek(Duration to) async => _player?.seek(to);

  /// Очередь целиком (для листа «Дальше» в плеере) и позиция в ней.
  List<NowPlaying> get queueView => List.unmodifiable(_queue);
  int get currentIndex => _index;

  /// Перейти на трек с индексом [i] в очереди (тап по строке в листе «Дальше»).
  Future<void> jumpTo(int i) async {
    final p = _player;
    if (p == null || i < 0 || i >= _queue.length) return;
    _reportSkip();
    await p.seek(Duration.zero, index: i);
  }

  Future<void> toggleShuffle() async {
    final p = _player;
    if (p == null) return;
    final v = !shuffle.value;
    await p.setShuffleModeEnabled(v);
    shuffle.value = v;
    // Перемешал руками — «радио по песне» больше не про этот порядок.
    if (v) radio.value = false;
  }

  /// Выключить «Радио по этой»: вернуть перемешивание Потока. Хвост очереди
  /// (уже подобранный по звуку) оставляем как есть — просто дальше играем
  /// вперемешку. Кнопка радио гаснет. Нужно, потому что второе нажатие на
  /// кнопку раньше просто пересобирало радио и выключить его было нечем
  /// (Alex, 06.09.2026).
  Future<void> stopRadio() async {
    final p = _player;
    if (p != null) {
      await p.setShuffleModeEnabled(true);
      shuffle.value = true;
    }
    radio.value = false;
  }

  /// «Радио по этой песне»: заменить хвост очереди (всё после текущей) на
  /// [tail] — уже упорядоченный по близости звучания список. Текущая песня
  /// не прерывается. Перемешивание выключаем — порядок теперь осмысленный.
  Future<void> setSimilarTail(List<NowPlaying> tail) async {
    final p = _player;
    final src = _source;
    if (p == null || src == null) return;
    await p.setShuffleModeEnabled(false);
    shuffle.value = false;
    if (_index + 1 < src.length) {
      await src.removeRange(_index + 1, src.length);
    }
    await src.addAll([for (final t in tail) AudioSource.uri(Uri.file(t.path))]);
    _queue = [..._queue.sublist(0, _index + 1), ...tail];
    radio.value = true;
  }

  /// Переставить трек в очереди (лист «Дальше»). Оба индекса — только
  /// среди ещё не сыгранных (> currentIndex), список в плеере других не
  /// показывает.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final src = _source;
    if (src == null) return;
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length ||
        oldIndex == newIndex ||
        oldIndex <= _index ||
        newIndex <= _index) {
      return;
    }
    await src.move(oldIndex, newIndex);
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
  }

  /// Убрать трек из очереди (смахнул в листе «Дальше»). Текущий и уже
  /// сыгранные трогать нельзя.
  Future<void> removeFromQueue(int index) async {
    final src = _source;
    if (src == null) return;
    if (index <= _index || index >= _queue.length) return;
    await src.removeAt(index);
    _queue.removeAt(index);
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

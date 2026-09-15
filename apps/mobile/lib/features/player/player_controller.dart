import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/player_issue_log.dart';

/// [tracks] переставленные так: сперва элемент с индексом [startIndex],
/// затем остальные — вперемешку. Используется вместо встроенного шаффла
/// just_audio (see `playQueue`) — тот шаффлит порядок воспроизведения
/// ВНУТРИ плеера отдельно от списка `_queue`, из-за чего подпись «Дальше»
/// и список очереди в UI показывали не ту песню, что реально играла
/// следующей (Alex TG 13.09.2026, скриншоты «Дальше: Shiny Happy People» /
/// реально играет «Get Away»). Свой шаффл — один список везде: очередь,
/// показ «Дальше», перестановка/удаление в ней.
@visibleForTesting
List<NowPlaying> shufflePinned(List<NowPlaying> tracks, int startIndex, [Random? rng]) {
  final start = tracks[startIndex.clamp(0, tracks.length - 1)];
  final rest = [for (final t in tracks) if (!identical(t, start)) t]..shuffle(rng);
  return [start, ...rest];
}

/// Чего из [all] ещё нет в [queue] (по id), вперемешку — для дозаписи новых
/// скачанных треков в хвост очереди Потока без перезарядки уже играющего
/// (Опус-ревью телефона 14.09.2026, пункт 4: раньше новые песни попадали в
/// Поток только после полного перезапуска приложения).
@visibleForTesting
List<NowPlaying> newTracksToAppend(List<NowPlaying> queue, List<NowPlaying> all, [Random? rng]) {
  final have = {for (final t in queue) t.id};
  return [for (final t in all) if (!have.contains(t.id)) t]..shuffle(rng);
}

/// [queue] без ещё не сыгранных (индекс > [afterIndex]) треков исполнителя
/// [artist] — «скрыть исполнителя» должно убрать его из очереди сразу, а не
/// просто дать доиграть уже поставленные следующие треки (пункт 6 того же
/// ревью).
@visibleForTesting
List<NowPlaying> withoutArtistAfter(List<NowPlaying> queue, int afterIndex, String artist) {
  return [
    for (var i = 0; i < queue.length; i++)
      if (i <= afterIndex || queue[i].artist != artist) queue[i],
  ];
}

/// Обёртка над проигрывателем. Держит очередь локальных файлов (офлайн),
/// отдаёт наружу простые ValueNotifier'ы для UI. Фон/локскрин — через
/// `audio_service` (см. audio_handler.dart). Гэплесс, нормализация —
/// следующими шагами.
class PlayerController {
  PlayerController({
    this.onPlay,
    this.onSkip,
    this.onComplete,
    this.onDuration,
    this.onMissingFile,
  }) {
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

  /// Файл трека пропал с телефона между тем, как он попал в очередь, и этим
  /// её пересбором (`_reloadFrom`) — трек молча пропускается, чтобы не
  /// повалить весь плеер (см. крэш `_reloadFrom`/«Source error»). Alex TG
  /// 15.09.2026, увидев «пропускается»: «давай чинить, а не пропускать» —
  /// сюда вешаем фоновую перекачку файла заново + `requeueTrack` по итогу.
  /// Зовётся один раз на трек (пока файл снова не появится через
  /// `requeueTrack` — тогда гейт снимается).
  final void Function(NowPlaying meta)? onMissingFile;

  AudioPlayer? _player;
  ConcatenatingAudioSource? _source;
  List<NowPlaying> _queue = const [];
  int _index = 0;
  String? _lastPlayId;
  final Set<String> _missingNotified = {};

  final ValueNotifier<NowPlaying?> now = ValueNotifier(null);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> shuffle = ValueNotifier(false);

  /// «Радио по этой песне» активно — хвост очереди выстроен по близости
  /// звучания к той песне, с которой радио запустили (06.09.2026).
  final ValueNotifier<bool> radio = ValueNotifier(false);

  /// Сколько треков было в «Моей музыке», когда вкладка «Поток» в последний
  /// раз строила/дополняла очередь — -1 значит ещё ни разу. Живёт здесь (не в
  /// StreamScreen), потому что StreamScreen пересоздаётся при каждом
  /// переключении вкладок, а очередь и то, что из неё уже сыграно —
  /// состояние самого плеера (см. stream_screen.dart _load, пункт 4).
  int streamQueueCount = -1;

  final _subs = <StreamSubscription<dynamic>>[];

  // Битый/недоступный файл в очереди раньше выбрасывал необработанную ошибку
  // из потока событий just_audio — и на некоторых телефонах падало всё
  // приложение (Alex TG 19028: «слушаю через колонку, разные песни, плеер
  // просто закрывается»). Теперь ошибку ловим: перескок на следующий трек,
  // приложение живо. Счётчик подряд — чтобы не крутиться вечно по битым.
  int _consecutiveErrors = 0;
  DateTime _lastErrorAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _onPlaybackError(Object e, StackTrace st) {
    // Это плеер САМ восстанавливается (перескок на следующий трек) — не
    // настоящее падение приложения, поэтому в CrashLog не пишем (тот только
    // для реальных крашей, main.dart). Отдельный тихий лог для диагностики.
    PlayerIssueLog.write(e, st, where: 'player_skip');
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
    // Шаффл — свой (переставляем сам список), а не встроенный в just_audio:
    // тот держит порядок воспроизведения отдельно от списка очереди, и
    // «Дальше» в UI начинает показывать не ту песню, что играет следующей.
    _queue = shuffle ? shufflePinned(tracks, startIndex) : List.of(tracks);
    _index = shuffle ? 0 : startIndex.clamp(0, tracks.length - 1);
    _prevIndex = _index; // новая очередь — не считаем сменой трека
    _userSeek = false;
    _lastPlayId = null;
    _consecutiveErrors = 0;
    radio.value = false;
    _preRadioTail = null;
    final p = _ensure();
    final src = ConcatenatingAudioSource(
      children: [for (final t in _queue) AudioSource.uri(Uri.file(t.path))],
    );
    _source = src;
    try {
      await p.setLoopMode(loop ? LoopMode.all : LoopMode.off);
      await p.setShuffleModeEnabled(false);
      this.shuffle.value = shuffle;
      await p.setAudioSource(src, initialIndex: _index, initialPosition: Duration.zero);
      now.value = _queue[_index];
      // currentIndexStream отдаст этот же индекс и запишет play — второй раз тут не зовём.
      if (autoplay) await p.play();
    } catch (e, st) {
      // Не роняем экран, с которого запустили: не настоящий краш — только
      // диагностика, дальше авто-перескок по битым разрулит _onPlaybackError.
      PlayerIssueLog.write(e, st, where: 'playQueue');
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

  /// Максимум треков в «хвосте» живой очереди за один присест. Построение
  /// `ConcatenatingAudioSource` на уже играющем плеере (`_reloadFrom`) нативно
  /// стоит ощутимо дороже с ростом числа элементов — на большой библиотеке
  /// (тысячи скачанных) весь хвост целиком тормозил интерфейс и вызывал
  /// заикание звука на 10-20 секунд (Alex 14.09.2026, сразу после включения
  /// радио — до этого фикса зацикливания хвост так большим никогда не был).
  /// `LoopMode.all` зациклит и такой урезанный хвост, когда он кончится —
  /// не бесконечное разнообразие за один присест, но без тормозов; догрузка
  /// по приближении к концу — отдельная задача, если этого будет мало.
  static const int _kMaxLiveTail = 150;

  List<NowPlaying> _capTail(List<NowPlaying> tail) =>
      tail.length > _kMaxLiveTail ? tail.sublist(0, _kMaxLiveTail) : tail;

  /// Перестроить очередь целиком через `setAudioSource` (тот же путь, что
  /// `playQueue`), сохранив позицию и не прерывая воспроизведение — вместо
  /// точечных `removeRange`/`addAll` на уже играющем `ConcatenatingAudioSource`.
  /// Правит баг: с `LoopMode.all` активным нативный плеер иногда уже
  /// готовится зациклиться на индекс 0 к моменту точечной правки хвоста, и
  /// добавленные через `addAll` треки не подхватывались — «радио»
  /// зацикливалось на текущей песне, хотя `queueView`/«Дальше» в интерфейсе
  /// уже показывали правильный порядок (Alex, голосовое 14.09.2026: «Дальше»
  /// правильный, а по факту играет та же песня заново). `_index` не меняем —
  /// текущий трек и его позиция в [newQueue] остаются на месте.
  Future<void> _reloadFrom(List<NowPlaying> newQueue) async {
    final p = _player;
    if (p == null) return;
    final wasPlaying = p.playing;
    final pos = p.position;
    // Файл трека мог не докачаться/пропасть между тем как он попал в
    // очередь и этим её пересбором — один битый путь раньше валил ВЕСЬ
    // setAudioSource целиком (Alex TG 15.09.2026, крэш «Source error» в
    // AudioPlayer._load через appendNewToQueue). Пропускаем такие точечно;
    // 0.._index не трогаем — это уже игравшая часть, заведомо цела.
    final valid = <NowPlaying>[];
    for (var i = 0; i < newQueue.length; i++) {
      final t = newQueue[i];
      if (i <= _index || File(t.path).existsSync()) {
        valid.add(t);
      } else if (_missingNotified.add(t.id)) {
        // Не просто пропускаем — просим докачать заново (Alex TG 15.09.2026:
        // «давай чинить, а не пропускать»). Один раз на трек, пока он не
        // вернётся через requeueTrack.
        onMissingFile?.call(t);
      }
    }
    final src = ConcatenatingAudioSource(
      children: [for (final t in valid) AudioSource.uri(Uri.file(t.path))],
    );
    _source = src;
    _queue = valid;
    await p.setAudioSource(src, initialIndex: _index, initialPosition: pos);
    if (wasPlaying) await p.play();
  }

  /// Хвост очереди КАК ОН БЫЛ до включения радио (снимок из `setSimilarTail`)
  /// — чтобы `stopRadio` мог вернуть настоящий широкий Поток, а не просто
  /// перемешать местами тот же узкий список «похожего» (баг: Alex TG
  /// 14.09.2026 — «когда я уже убрал радио, всё равно играли похожие
  /// песни» — раньше `stopRadio` тасовал ИМЕННО отобранные радио треки,
  /// набор при этом не менялся, только порядок внутри него).
  List<NowPlaying>? _preRadioTail;

  /// Выключить «Радио по этой»: вернуть широкий Поток (см. `_preRadioTail`)
  /// в перемешанном виде — сам перемешиваем (см. `playQueue`, встроенный
  /// шаффл just_audio не используем, чтобы «Дальше» не расходилось с
  /// реальным порядком). Уже сыгранное не трогаем. Кнопка радио гаснет.
  /// Нужно, потому что второе нажатие на кнопку раньше просто пересобирало
  /// радио и выключить его было нечем (Alex, 06.09.2026).
  Future<void> stopRadio() async {
    final saved = _preRadioTail;
    if (saved != null && saved.isNotEmpty) {
      final tail = _capTail([...saved]..shuffle());
      await _reloadFrom([..._queue.sublist(0, _index + 1), ...tail]);
    } else if (_index + 1 < _queue.length) {
      final tail = _capTail(_queue.sublist(_index + 1)..shuffle());
      await _reloadFrom([..._queue.sublist(0, _index + 1), ...tail]);
    }
    _preRadioTail = null;
    shuffle.value = true;
    radio.value = false;
  }

  /// «Радио по этой песне»: заменить хвост очереди (всё после текущей) на
  /// [tail] — уже упорядоченный по близости звучания список. Текущая песня
  /// не прерывается. Перемешивание выключаем — порядок теперь осмысленный.
  Future<void> setSimilarTail(List<NowPlaying> tail) async {
    if (_player == null) return;
    await _player!.setShuffleModeEnabled(false);
    shuffle.value = false;
    // Снимок ДО замены — только пока радио ещё не было включено (кнопка
    // радио при повторном нажатии всегда сперва выключает его, см.
    // player_view.dart _radio — так что setSimilarTail не вызывается
    // повторно поверх уже идущего радио, снимок не затрётся похожим же).
    _preRadioTail = _queue.sublist(_index + 1);
    await _reloadFrom([..._queue.sublist(0, _index + 1), ..._capTail(tail)]);
    radio.value = true;
  }

  /// Дозаписать в хвост «Радио по этой» ещё похожих треков, не заменяя уже
  /// поставленные — вторая, фоновая порция после быстрого первого куска
  /// (Alex TG 14.09.2026: «подбирать кусочками... прослушал первые — ещё
  /// подгружает» — вместо одного похода за всеми сразу, который на реальном
  /// телефоне занимал 8+ секунд молчания, см. журнал). Не трогает
  /// `_preRadioTail` — она снята один раз при входе в радио
  /// (`setSimilarTail`), а не при каждой дозаписи. Если радио уже выключили,
  /// пока фоновая порция считалась — не подмешиваем её в обычный Поток.
  Future<void> extendSimilarTail(List<NowPlaying> more) async {
    if (_player == null || !radio.value) return;
    final have = {for (final t in _queue) t.id};
    final fresh = [for (final t in more) if (!have.contains(t.id)) t];
    if (fresh.isEmpty) return;
    final tail = _capTail([..._queue.sublist(_index + 1), ...fresh]);
    await _reloadFrom([..._queue.sublist(0, _index + 1), ...tail]);
  }

  /// Добавить в хвост очереди новые скачанные треки (не прерывая текущий) —
  /// см. `newTracksToAppend` и stream_screen.dart _load (пункт 4). Через
  /// `_reloadFrom` (не точечный `addAll`) по той же причине, что и
  /// `stopRadio`/`setSimilarTail` — не рискуем тем же классом бага зацикливания.
  Future<void> appendNewToQueue(List<NowPlaying> all) async {
    if (_source == null) return;
    final fresh = newTracksToAppend(_queue, all);
    if (fresh.isEmpty) return;
    await _reloadFrom([..._queue, ...fresh]);
  }

  /// Файл трека [t] докачали заново после `onMissingFile` (см.
  /// `DownloadsRepo.redownloadMissingFile`) — вернуть его в конец очереди.
  /// Уже играющее не трогаем; если трека и так уже нет в очереди (плеер тем
  /// временем ушёл дальше без него) — просто снимаем гейт на повтор.
  Future<void> requeueTrack(NowPlaying t) async {
    _missingNotified.remove(t.id);
    if (_source == null || _queue.any((x) => x.id == t.id)) return;
    await _reloadFrom([..._queue, t]);
  }

  /// Убрать из очереди все ещё не сыгранные треки исполнителя [artist] —
  /// см. `withoutArtistAfter` и player_view.dart _hideArtist (пункт 6).
  Future<void> removeArtistFromQueue(String artist) async {
    if (_source == null) return;
    final newQueue = withoutArtistAfter(_queue, _index, artist);
    if (newQueue.length == _queue.length) return;
    await _reloadFrom(newQueue);
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

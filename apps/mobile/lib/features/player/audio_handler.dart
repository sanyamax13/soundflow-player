import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';

import '../../core/app_log.dart';
import '../../core/black_box.dart';
import '../../core/crash_log.dart';
import 'player_controller.dart';

/// Мост между [PlayerController] и системой Android — чтобы кнопки play/
/// пауза/вперёд/назад с Bluetooth-магнитолы в машине, наушников, руля и
/// экрана блокировки реально доходили до плеера. Добавлено 05.09.2026: Alex
/// подключил телефон к магнитоле в машине, кнопки не работали — без этого
/// моста Android не знает, что у приложения вообще есть чем управлять.
///
/// Сам плеер (весь код проигрывания) не трогаем — этот класс только
/// пересылает команды туда-обратно между [PlayerController] и `audio_service`.
class SoundFlowAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  SoundFlowAudioHandler(this._player) {
    _player.now.addListener(_syncMediaItem);
    _player.playing.addListener(_syncPlaybackState);
    _player.duration.addListener(_syncPlaybackState);
    // Пересборка очереди (радио, дозапись, докачка пропавшего файла) может
    // сбросить системную медиа-сессию под капотом just_audio — а playing/
    // duration после такой пересборки часто НЕ меняются, значит слушатели
    // выше не сработают и Android останется без переотправленного списка
    // кнопок. Alex TG 15.09.2026: «сломалось блютуз управление, не
    // переключается» (в самом приложении работает). reloadSeq растёт на
    // КАЖДОЙ пересборке гарантированно — переотправляем и то, и то.
    _player.reloadSeq.addListener(_onReload);
    _syncMediaItem();
    _syncPlaybackState();
  }

  void _onReload() {
    _syncMediaItem();
    _syncPlaybackState();
  }

  final PlayerController _player;

  void _syncMediaItem() {
    final now = _player.now.value;
    if (now == null) {
      mediaItem.add(null);
      return;
    }
    final coverPath = now.coverPath;
    final hasCover = coverPath != null && File(coverPath).existsSync();
    mediaItem.add(MediaItem(
      id: now.id,
      title: now.title,
      artist: now.artist,
      duration: _player.duration.value,
      artUri: hasCover ? Uri.file(coverPath) : null,
    ));
  }

  void _syncPlaybackState() {
    final playing = _player.playing.value;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      playing: playing,
      processingState: AudioProcessingState.ready,
      updatePosition: _player.position.value,
    ));
  }

  @override
  Future<void> play() {
    BlackBox.log('media_btn', {'cmd': 'play'});
    return _player.play();
  }

  @override
  Future<void> pause() {
    BlackBox.log('media_btn', {'cmd': 'pause'});
    return _player.pause();
  }

  // Alex TG 15.09.2026: «сломалось блютуз управление, не переключается» (в
  // приложении кнопки вперёд/назад работают, значит дело либо в том, что
  // Android не доносит нажатие с гарнитуры досюда, либо в чём-то именно
  // на этом пути). Лога раньше не было — событие тут же в AppLog покажет,
  // дошло ли нажатие вообще: если после жалобы Alex в журнале НЕТ такой
  // строки — Android/гарнитура не доносят команду, дело не в SoundFlow.
  @override
  Future<void> skipToNext() {
    BlackBox.log('media_btn', {'cmd': 'next'});
    AppLog.event('bt_skip_next');
    return _player.next();
  }

  @override
  Future<void> skipToPrevious() {
    BlackBox.log('media_btn', {'cmd': 'prev'});
    AppLog.event('bt_skip_prev');
    return _player.prev();
  }

  @override
  Future<void> seek(Duration position) {
    BlackBox.log('media_btn', {'cmd': 'seek', 'to_ms': position.inMilliseconds});
    return _player.seek(position);
  }

  @override
  Future<void> stop() async {
    BlackBox.log('media_btn', {'cmd': 'stop'});
    await _player.pause();
    // Убирает уведомление и снимает foreground-сервис — иначе он висит и
    // держит приложение живым в фоне.
    await super.stop();
  }

  /// Пользователь смахнул приложение из «недавних». По умолчанию Android
  /// оставляет музыку играть в фоне — Alex этого не ждёт (06.09.2026:
  /// «выгружаю плеер, а он всё равно играет»). Глушим и гасим сессию.
  ///
  /// 24.09.2026: Alex сообщил случай, когда после смахивания музыка НЕ
  /// остановилась (и уведомление плеера пропало, осталось только системное
  /// «подключено по блютуз») — без падения в «Последнем сбое», значит либо
  /// Android вообще не позвал этот метод, либо позвал, но что-то внутри
  /// тихо не выполнилось. Метки в журнале — чтобы при повторе увидеть,
  /// какой из двух случаев это был, без USB-кабеля и логов Android.
  @override
  Future<void> onTaskRemoved() async {
    BlackBox.log('task_removed');
    await BlackBox.flush();
    unawaited(AppLog.event('task_removed_start'));
    try {
      await stop();
    } catch (e, st) {
      await CrashLog.write(e, st, where: 'onTaskRemoved');
    }
    await super.onTaskRemoved();
    unawaited(AppLog.event('task_removed_done'));
  }
}

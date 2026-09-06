import 'dart:io';

import 'package:audio_service/audio_service.dart';

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
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.prev();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.pause();
    // Убирает уведомление и снимает foreground-сервис — иначе он висит и
    // держит приложение живым в фоне.
    await super.stop();
  }

  /// Пользователь смахнул приложение из «недавних». По умолчанию Android
  /// оставляет музыку играть в фоне — Alex этого не ждёт (06.09.2026:
  /// «выгружаю плеер, а он всё равно играет»). Глушим и гасим сессию.
  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }
}

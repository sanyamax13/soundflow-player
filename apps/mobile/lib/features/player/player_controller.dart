import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Обёртка над проигрывателем. На этом шаге — только локальные файлы
/// (офлайн). Фон/локскрин (`audio_service`), гэплесс, нормализация —
/// следующими шагами.
class PlayerController {
  AudioPlayer? _player;

  /// Что играет сейчас: null — ничего.
  final ValueNotifier<NowPlaying?> now = ValueNotifier(null);

  /// Идёт ли воспроизведение.
  final ValueNotifier<bool> playing = ValueNotifier(false);

  AudioPlayer _ensure() {
    final p = _player;
    if (p != null) return p;
    final np = AudioPlayer();
    np.playingStream.listen((v) => playing.value = v);
    np.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) playing.value = false;
    });
    _player = np;
    return np;
  }

  Future<void> playLocalFile(String path, NowPlaying meta) async {
    now.value = meta;
    final p = _ensure();
    await p.setFilePath(path);
    await p.play();
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
    } else {
      await p.play();
    }
  }

  Future<void> dispose() async => _player?.dispose();
}

class NowPlaying {
  const NowPlaying({required this.id, required this.title, required this.artist});
  final String id;
  final String title;
  final String artist;
}

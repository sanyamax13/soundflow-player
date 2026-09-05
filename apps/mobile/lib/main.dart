import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/shell.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'data/db.dart';
import 'data/downloads_repo.dart';
import 'data/sync_repo.dart';
import 'features/player/audio_handler.dart';
import 'features/player/player_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = Api();
  final db = await Db.open();
  final sync = SyncRepo(api, db);
  final downloads = DownloadsRepo(api, db, sync);
  final player = PlayerController(
    onPlay: (m) => sync.record('play', trackId: m.id),
    onSkip: (m) => sync.record('skip', trackId: m.id),
  );
  // Медиа-сессия Android — чтобы кнопки на Bluetooth-магнитоле в машине,
  // наушниках, руле и экране блокировки управляли плеером (05.09.2026,
  // просьба Alex — без этого магнитола ничего не переключала).
  await AudioService.init(
    builder: () => SoundFlowAudioHandler(player),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'ru.soundflow.soundflow.audio',
      androidNotificationChannelName: 'SoundFlow — плеер',
      androidNotificationOngoing: true,
    ),
  );
  runApp(SoundFlowApp(api: api, downloads: downloads, player: player, sync: sync));
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({
    super.key,
    required this.api,
    required this.downloads,
    required this.player,
    required this.sync,
  });

  final Api api;
  final DownloadsRepo downloads;
  final PlayerController player;
  final SyncRepo sync;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: api,
      downloads: downloads,
      player: player,
      sync: sync,
      child: MaterialApp(
        title: 'SoundFlow',
        debugShowCheckedModeBanner: false,
        theme: Afisha.theme(),
        // Входа нет — сразу вкладки. Плеер личный, сервер в домашней сети.
        home: const Shell(),
      ),
    );
  }
}

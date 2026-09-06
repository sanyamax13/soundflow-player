import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/shell.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'data/auto_sync.dart';
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
  // Докачать обложки уже скачанным трекам без неё — фоном, не ждём (может
  // быть небыстро на большой библиотеке). См. downloads_repo.dart, 05.09.2026.
  unawaited(downloads.backfillCovers());
  // Сам отправляет накопленные лайки/удаления на сервер, как появится связь
  // (06.09.2026). Живёт всё время работы приложения.
  AutoSync(sync, downloads).start();
  runApp(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        downloadsProvider.overrideWithValue(downloads),
        playerProvider.overrideWithValue(player),
        syncProvider.overrideWithValue(sync),
      ],
      child: const SoundFlowApp(),
    ),
  );
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundFlow',
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      // Входа нет — сразу вкладки. Плеер личный, сервер в домашней сети.
      home: const Shell(),
    );
  }
}

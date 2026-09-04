import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/shell.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'data/db.dart';
import 'data/downloads_repo.dart';
import 'features/player/player_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = Api();
  final db = await Db.open();
  final downloads = DownloadsRepo(api, db);
  final player = PlayerController();
  runApp(SoundFlowApp(api: api, downloads: downloads, player: player));
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({
    super.key,
    required this.api,
    required this.downloads,
    required this.player,
  });

  final Api api;
  final DownloadsRepo downloads;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: api,
      downloads: downloads,
      player: player,
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

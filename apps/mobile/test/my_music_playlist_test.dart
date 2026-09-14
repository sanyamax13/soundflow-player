import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakePlayerController extends PlayerController {
  List<NowPlaying>? lastQueue;
  int? lastStartIndex;
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) async {
    lastQueue = tracks;
    lastStartIndex = startIndex;
  }
}

Future<Widget> _appWith(Db db, PlayerController player) async {
  final api = Api();
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player),
      syncProvider.overrideWithValue(sync),
    ],
    child: const SoundFlowApp(),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  // Каждый исполнитель ниже — с ОДНОЙ песней, чтобы обе строки в «Моей
  // музыке» рендерились как _soloTrackRow (не папкой) — именно этот случай
  // раньше ставил очередь из одной-единственной песни (Alex TG 14.09.2026:
  // «нажимаю на первую, играет, следующая не переходит, начинается заново»).
  testWidgets('тап по одиночной песне ставит очередь из всего списка, не одну песню', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(
      id: 'a', title: 'Песня А', artist: 'Исполнитель А', path: '/tmp/a', bytes: 1, addedAt: 1,
    ));
    await db.upsertDownloaded(DownloadedTrack(
      id: 'b', title: 'Песня Б', artist: 'Исполнитель Б', path: '/tmp/b', bytes: 1, addedAt: 2,
    ));

    final player = _FakePlayerController();
    await tester.pumpWidget(await _appWith(db, player));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Моя музыка'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Песня А'));
    await tester.pumpAndSettle();

    final queue = player.lastQueue;
    final startIndex = player.lastStartIndex;
    expect(queue, isNotNull);
    expect(queue, hasLength(2)); // раньше тут была очередь из ОДНОЙ песни
    expect(startIndex, isNotNull);
    expect(queue![startIndex!].id, 'a'); // очередь начинается с той, по которой тапнули
    await db.close();
  });
}

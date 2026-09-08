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
import 'package:soundflow/features/player/player_view.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];
  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async =>
      (
        ids: [for (final id in candidateIds) if (id != seedId) id],
        reordered: false,
      );
}

Future<Widget> _app({List<DownloadedTrack> downloaded = const []}) async {
  final api = _FakeApi();
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  for (final t in downloaded) {
    await db.upsertDownloaded(t);
  }
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(PlayerController()),
      syncProvider.overrideWithValue(sync),
    ],
    child: const SoundFlowApp(),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('Поток без скачанного — подсказка скачать музыку', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    expect(find.text('В Потоке пока пусто'), findsOneWidget);
    expect(find.text('Открыть «Мою музыку»'), findsOneWidget);
  });

  testWidgets('кнопка из пустого Потока ведёт в «Мою музыку»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть «Мою музыку»'));
    await tester.pumpAndSettle();

    expect(find.text('Пока ничего не скачано'), findsOneWidget);
  });

  testWidgets(
      'Поток со скачанным — полноэкранный плеер, сам не заводит (06.09.2026)',
      (tester) async {
    final app = await _app(downloaded: [
      DownloadedTrack(
          id: 'a', title: 'Песня А', artist: 'Кто-то', path: '/tmp/a', bytes: 10, addedAt: 1),
      DownloadedTrack(
          id: 'b', title: 'Песня Б', artist: 'Кто-то', path: '/tmp/b', bytes: 20, addedAt: 2),
    ]);
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app);
    // Не pumpAndSettle: в тесте нет аудиоплагина, у плеера висят стримы.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Вкладка показывает полноэкранный плеер, а не голую кнопку play. Строки
    // «Слушать вперемешку — N песен» нет; музыка не заводится сама — только
    // по нажатию (Alex 06.09.2026: очередь заряжается на паузе).
    expect(find.byType(PlayerView), findsOneWidget);
    expect(find.textContaining('Слушать вперемешку'), findsNothing);
  });
}

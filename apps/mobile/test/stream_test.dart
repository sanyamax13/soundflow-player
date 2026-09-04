import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks() async => const [];
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
  return SoundFlowApp(
    api: api,
    downloads: DownloadsRepo(api, db, sync),
    player: PlayerController(),
    sync: sync,
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

  testWidgets('Поток со скачанным — кнопка «Слушать» и список', (tester) async {
    await tester.pumpWidget(await _app(downloaded: [
      DownloadedTrack(
          id: 'a', title: 'Песня А', artist: 'Кто-то', path: '/tmp/a', bytes: 10, addedAt: 1),
      DownloadedTrack(
          id: 'b', title: 'Песня Б', artist: 'Кто-то', path: '/tmp/b', bytes: 20, addedAt: 2),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Слушать вперемешку'), findsOneWidget);
    expect(find.text('2 песен на телефоне'), findsOneWidget);
    expect(find.text('Песня А'), findsOneWidget);
    expect(find.text('Песня Б'), findsOneWidget);
  });
}

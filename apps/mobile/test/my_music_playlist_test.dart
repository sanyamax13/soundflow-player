import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
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
    Duration initialPosition = Duration.zero,
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
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
    ],
    child: const SoundFlowApp(),
  );
}

DownloadedTrack _t(String id, String artist, String title, int at) => DownloadedTrack(
      id: id, title: title, artist: artist, path: '/tmp/$id', bytes: 1, addedAt: at,
    );

/// Открывает «Мою музыку» с тремя песнями: Beatles (одна) и «Исполнитель А» (две).
/// Очередь Потока, что записал сам Поток при открытии, сбрасываем — дальше
/// проверяем только то, что поставила «Моя музыка».
Future<(Db, _FakePlayerController)> _openMyMusic(WidgetTester tester,
    {List<DownloadedTrack>? tracks}) async {
  await tester.binding.setSurfaceSize(const Size(400, 860));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  for (final t in tracks ??
      [
        _t('y', 'Beatles', 'Yesterday', 1),
        _t('a2', 'Исполнитель А', 'Песня А2', 2),
        _t('a1', 'Исполнитель А', 'Песня А1', 3),
      ]) {
    await db.upsertDownloaded(t);
  }

  final player = _FakePlayerController();
  await tester.pumpWidget(await _appWith(db, player));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Моя музыка'));
  await tester.pumpAndSettle();
  player.lastQueue = null;
  player.lastStartIndex = null;
  addTearDown(db.close);
  return (db, player);
}

void main() {
  setUpAll(sqfliteFfiInit);

  // Alex TG 20134 (20.09.2026), вид «Б»: все исполнители папками — и с одной
  // песней тоже — по алфавиту; латиница раньше кириллицы; в шапке — только
  // «N песни» (без числа исполнителей и гигабайтов).
  testWidgets('все исполнители папками по алфавиту, в шапке только число песен', (tester) async {
    await _openMyMusic(tester);

    expect(find.text('3 песни на телефоне'), findsOneWidget);
    expect(find.text('Beatles'), findsOneWidget);
    expect(find.text('1 песня'), findsOneWidget); // одна песня — тоже папка, не строка-песня
    expect(find.text('Yesterday'), findsNothing);
    expect(find.text('Исполнитель А'), findsOneWidget);
    expect(find.text('2 песни'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Beatles')).dy,
        lessThan(tester.getTopLeft(find.text('Исполнитель А')).dy));
    expect(find.byIcon(Icons.refresh), findsNothing); // кнопки обновления нет — обновляется само
  });

  // Раньше тап по одиночной песне ставил очередь из ВСЕХ песен списка (Alex
  // TG 14.09.2026: «нажимаю на первую, играет, следующая не переходит»). Теперь
  // играем песни той папки, что открыл.
  testWidgets('тап по песне в папке ставит очередь из песен этого исполнителя', (tester) async {
    final (_, player) = await _openMyMusic(tester);

    await tester.tap(find.text('Исполнитель А'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Песня А2'));
    await tester.pumpAndSettle();

    final queue = player.lastQueue;
    expect(queue, isNotNull);
    expect(queue!.map((t) => t.id), ['a1', 'a2']); // по названию
    expect(queue[player.lastStartIndex!].id, 'a2'); // очередь начинается с той, по которой тапнули
  });

  testWidgets('поиск находит песни и играет найденные подряд', (tester) async {
    final (_, player) = await _openMyMusic(tester);

    await tester.enterText(find.byType(TextField), 'песня');
    await tester.pumpAndSettle();
    expect(find.text('ПЕСНИ'), findsOneWidget);
    expect(find.text('Yesterday'), findsNothing);

    await tester.tap(find.text('Песня А2'));
    await tester.pumpAndSettle();

    expect(player.lastQueue!.map((t) => t.id), ['a1', 'a2']);
    expect(player.lastQueue![player.lastStartIndex!].id, 'a2');
  });

  testWidgets('поиск по исполнителю показывает и папку, и его песни', (tester) async {
    await _openMyMusic(tester);

    await tester.enterText(find.byType(TextField), 'beat');
    await tester.pumpAndSettle();

    expect(find.text('ИСПОЛНИТЕЛИ'), findsOneWidget);
    expect(find.text('Beatles'), findsNWidgets(2)); // название папки и подпись «исполнитель» под его песней
    expect(find.text('ПЕСНИ'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget); // и его песня
    expect(find.text('Исполнитель А'), findsNothing);
  });

  testWidgets('поиск без совпадений — честный текст', (tester) async {
    await _openMyMusic(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('Ничего не нашлось по «zzz»'), findsOneWidget);
  });

  // Полоска букв справа: палец ведёт вниз до конца — список прыгает к последней букве.
  testWidgets('полоска букв: ведём пальцем вниз — список прыгает к последней букве', (tester) async {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    await _openMyMusic(tester, tracks: [
      for (var i = 0; i < letters.length; i++) _t('t$i', '${letters[i]}ax', 'Song $i', i),
    ]);
    expect(find.text('Aax'), findsOneWidget);
    expect(find.text('Zax'), findsNothing); // 26 строк по 76 — до Z ещё далеко (не построена)

    await tester.dragFrom(const Offset(388, 220), const Offset(0, 560));
    await tester.pumpAndSettle();

    expect(find.text('Zax'), findsOneWidget);
    expect(find.text('Aax'), findsNothing);
  });

  // Баг из разбора дизайна 26.09.2026: после «Скачать» список «Моей музыки» оставался пустым до
  // перезапуска. Докачалась песня (changes++) — список перечитывается сам.
  testWidgets('докачалась песня — «Моя музыка» показывает её без перезапуска', (tester) async {
    final (db, _) = await _openMyMusic(tester, tracks: const []);
    expect(find.text('Beatles'), findsNothing);

    await db.upsertDownloaded(_t('y', 'Beatles', 'Yesterday', 1));
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    container.read(downloadsProvider).changes.value++;
    await tester.pump(const Duration(seconds: 1)); // пачка событий сводится в одно обновление
    await tester.pumpAndSettle();

    expect(find.text('Beatles'), findsOneWidget);
  });
}

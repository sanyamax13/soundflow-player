import 'dart:async';
import 'dart:convert';

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

/// Плеер, у которого зарядка очереди «долгая»: висит, пока тест не откроет
/// [gate] (на телефоне это секунды — порядок под вкус + загрузка источника).
/// `now` так и остаётся пустым — как если бы очередь не собралась.
class _SlowPlayer extends PlayerController {
  final gate = Completer<void>();
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) =>
      gate.future;
}

/// Плеер, который ничего не играет, а только записывает, что с ним делал Поток:
/// `playQueue` ведёт себя как настоящий (сбрасывает счётчик очереди Потока).
class _RecordingPlayer extends PlayerController {
  final calls = <String>[];
  List<NowPlaying>? takenOver;
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) async {
    streamQueueCount = -1;
    calls.add('playQueue');
    now.value = tracks[startIndex];
  }

  @override
  Future<void> takeOverWithStream(List<NowPlaying> stream) async {
    calls.add('takeOver');
    takenOver = stream;
  }

  @override
  Future<void> appendNewToQueue(List<NowPlaying> all) async => calls.add('append');
}

/// Плеер для проверки кэша холодного старта: зарядка из кэша (playQueue)
/// проходит сразу, а «настоящее» переключение (takeOverWithStream) зависает
/// на [hangTakeOver] — имитирует медленную реальную загрузку из базы.
class _PrimeThenHangPlayer extends PlayerController {
  final calls = <String>[];
  final hangTakeOver = Completer<void>();
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) async {
    streamQueueCount = -1;
    calls.add('playQueue');
    now.value = tracks[startIndex];
  }

  @override
  Future<void> takeOverWithStream(List<NowPlaying> stream) async {
    calls.add('takeOver');
    await hangTakeOver.future;
  }
}

const _someoneElse =
    NowPlaying(id: 'fav1', title: 'Из избранного', artist: 'Кто-то', path: '/tmp/fav1');

List<DownloadedTrack> _twoTracks() => [
      DownloadedTrack(
          id: 'a', title: 'Песня А', artist: 'Кто-то', path: '/tmp/a', bytes: 10, addedAt: 1),
      DownloadedTrack(
          id: 'b', title: 'Песня Б', artist: 'Кто-то', path: '/tmp/b', bytes: 20, addedAt: 2),
    ];

Future<void> _openStream(WidgetTester tester, Widget app) async {
  await tester.binding.setSurfaceSize(const Size(400, 860));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(app);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<Widget> _app({
  List<DownloadedTrack> downloaded = const [],
  PlayerController? player,
}) async {
  final api = _FakeApi();
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  // sqflite кэширует открытые соединения по пути (singleInstance по
  // умолчанию) — без закрытия все тесты в файле делили бы один и тот же
  // ":memory:" и видели kv-записи друг друга (поймано тестом «Поток» после
  // добавления кэша последней очереди, stream_screen.dart).
  addTearDown(db.close);
  for (final t in downloaded) {
    await db.upsertDownloaded(t);
  }
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player ?? PlayerController()),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
    ],
    child: const SoundFlowApp(),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  // Кнопки «Скачать музыку» больше нет (Alex TG 20158, 20167): что качать,
  // решает компьютер, телефон только предлагает — карточка и плашка.
  testWidgets('Поток без скачанного — подсказка, без кнопки «Скачать музыку»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    expect(find.text('В Потоке пока пусто'), findsOneWidget);
    expect(find.text('Скачать музыку'), findsNothing);
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

  // Alex TG 19950 (19.09.2026): «вначале плеер запускается, говорит что нет
  // песен, через несколько секунд песни появляются». Пока очередь заряжается,
  // вместо «Ничего не играет» — колесо; текст только если очередь не собралась.
  testWidgets('пока очередь заряжается — колесо, а не «Ничего не играет»',
      (tester) async {
    final player = _SlowPlayer();
    final app = await _app(player: player, downloaded: [
      DownloadedTrack(
          id: 'a', title: 'Песня А', artist: 'Кто-то', path: '/tmp/a', bytes: 10, addedAt: 1),
    ]);
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PlayerView), findsOneWidget);
    expect(find.text('Ничего не играет'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // очередь «зарядилась», но игрока в ней нет (now пуст) — честный текст
    player.gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ничего не играет'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // Alex TG 20135 (20.09.2026): «нажал на избранное, слушаю оттуда, перешёл на
  // Поток — играет дальше избранное, подобранные в Потоке уже не включишь».
  group('Поток забирает плеер у чужой очереди', () {
    testWidgets('играет чужое (после «Моей музыки») — Поток ставит свою очередь', (tester) async {
      final player = _RecordingPlayer()..now.value = _someoneElse; // счётчик -1: очередь не Потока
      await _openStream(tester, await _app(player: player, downloaded: _twoTracks()));

      expect(player.calls, ['takeOver']); // не playQueue (это бы оборвало песню) и не «дозапись в хвост»
      expect(player.takenOver!.map((t) => t.id).toSet(), {'a', 'b'});
      expect(player.streamQueueCount, 2);
    });

    testWidgets('очередь уже Потока и ничего не изменилось — не трогаем', (tester) async {
      final player = _RecordingPlayer()
        ..now.value = _someoneElse
        ..streamQueueCount = 2;
      await _openStream(tester, await _app(player: player, downloaded: _twoTracks()));

      expect(player.calls, isEmpty);
    });

    testWidgets('в библиотеке прибавилось — дозапись, а не замена', (tester) async {
      final player = _RecordingPlayer()
        ..now.value = _someoneElse
        ..streamQueueCount = 1; // Поток строил очередь, когда песня была одна
      await _openStream(tester, await _app(player: player, downloaded: _twoTracks()));

      expect(player.calls, ['append']);
      expect(player.streamQueueCount, 2);
    });

    testWidgets('плеер пуст — как раньше: заряжаем на паузе', (tester) async {
      final player = _RecordingPlayer();
      await _openStream(tester, await _app(player: player, downloaded: _twoTracks()));

      expect(player.calls, ['playQueue']);
      expect(player.streamQueueCount, 2); // playQueue сбросил в -1, Поток заявил свою уже после
    });
  });

  // Alex TG 24.09.2026: после полного закрытия приложения (Android убил
  // процесс) список должен появиться сразу, а не крутиться колесо, пока
  // настоящая загрузка из базы досчитывается в фоне.
  testWidgets('холодный старт с кэшем от прошлого раза — список сразу, без колеса',
      (tester) async {
    final player = _PrimeThenHangPlayer();
    final api = _FakeApi();
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    addTearDown(db.close);
    for (final t in _twoTracks()) {
      await db.upsertDownloaded(t);
    }
    await db.kvSet(
      'stream_cache_queue',
      jsonEncode([
        {'id': 'a', 'title': 'Песня А', 'artist': 'Кто-то', 'path': '/tmp/a', 'cover': null},
      ]),
    );
    final sync = SyncRepo(api, db);
    final app = ProviderScope(
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
    await _openStream(tester, app);

    // Кэш сработал почти сразу — список уже виден, колеса нет, хотя
    // «настоящая» подгрузка (takeOver) ещё зависла.
    expect(find.byType(PlayerView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(player.calls, ['playQueue', 'takeOver']);

    player.hangTakeOver.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.calls, ['playQueue', 'takeOver']);
    expect(player.streamQueueCount, 2);
  });
}

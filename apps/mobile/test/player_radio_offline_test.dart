import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/local_taste.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

/// Сервер на нажатие «радио» спрашиваться НЕ должен (Alex TG 19.09.2026:
/// сервер отдал отпечатки заранее, дальше телефон сам) — любое обращение
/// считается, тесты проверяют, что счётчики нулевые. Сеть при этом «лежит»:
/// если код всё же пойдёт к серверу, он получит ошибку, а не тихий успех.
class _ServerMustNotBeAsked extends Api {
  int streamOrderCalls = 0;
  int trackVectorsCalls = 0;

  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    streamOrderCalls++;
    throw DioException(requestOptions: RequestOptions(path: '/v1/stream/order'));
  }

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    trackVectorsCalls++;
    throw DioException(requestOptions: RequestOptions(path: '/api/tracks/vectors'));
  }
}

/// Сервер жив, но отпечатка этой песни не знает — отдаёт пустой ответ.
class _ServerKnowsNoFingerprint extends Api {
  final List<List<String>> trackVectorsCalls = [];

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    trackVectorsCalls.add(ids);
    return {};
  }
}

/// Сервер отдаёт отпечатки по запросу — для «подтянуть один недостающий».
class _ServerGivesVectors extends Api {
  _ServerGivesVectors(this.vectors);

  final Map<String, Uint8List> vectors;
  final List<List<String>> trackVectorsCalls = [];

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    trackVectorsCalls.add(ids);
    return {for (final id in ids) id: ?vectors[id]};
  }
}

/// В тесте нет аудиоплагина (см. stream_test.dart) — реальный
/// PlayerController.setSimilarTail трогает just_audio/ConcatenatingAudioSource
/// и виснет без платформенной реализации. Подменяем только этот метод —
/// проверяем, что фолбэк ДОШЁЛ до вызова и с каким списком, не поведение
/// самого плеера.
class _FakePlayerController extends PlayerController {
  final List<List<NowPlaying>> similarTailCalls = [];
  final List<List<NowPlaying>> extendCalls = [];
  @override
  Future<void> setSimilarTail(List<NowPlaying> tail) async {
    similarTailCalls.add(tail);
  }

  @override
  Future<void> extendSimilarTail(List<NowPlaying> more) async {
    extendCalls.add(more);
  }
}

Uint8List _vecBytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Future<Widget> _appWith(Api api, Db db, {PlayerController? player}) async {
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
  // `Isolate.run` (см. local_taste.dart offlineComputeRunner) не завершается
  // под `flutter test` — проверено отдельным пробным тестом
  // (Isolate.run(() => 1 + 1) не отвечает за 30 сек, это ограничение
  // тестового раннера, не баг счёта) — здесь считаем прямо, синхронно.
  setUp(() => offlineComputeRunner = <T>(body) async => body());
  tearDown(() => offlineComputeRunner = <T>(body) => Isolate.run(body));

  testWidgets('отпечатки уже на телефоне — радио собирается сразу, сервер не спрашивается', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(id: 'a', title: 'A', artist: 'X', path: '/tmp/a', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'b', title: 'B', artist: 'Y', path: '/tmp/b', bytes: 1, addedAt: 2));
    await db.upsertDownloaded(DownloadedTrack(id: 'c', title: 'C', artist: 'Z', path: '/tmp/c', bytes: 1, addedAt: 3));
    // Углы 0°/30°/60° друг от друга — не доли градуса, как раньше
    // ([0.9,0.1] к [1,0] давал cosine≈0.994): после калибровки
    // duplicateSimThreshold (0.98, Alex TG 14.09.2026) такая близость
    // считалась бы «тот же трек», а тесту нужны три РАЗНЫХ похожих трека,
    // независимо от того, какой из них окажется «сейчас играет».
    await db.setTrackVector('a', _vecBytes([1, 0]));
    await db.setTrackVector('b', _vecBytes([0.866, 0.5]));
    await db.setTrackVector('c', _vecBytes([0.5, 0.866]));
    final player = _FakePlayerController();
    final api = _ServerMustNotBeAsked();

    await tester.pumpWidget(await _appWith(api, db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Радио — значок ∞ в панели «Дальше» внизу плеера (player_view.dart,
    // InkWell key: 'radio_button'; переехал с таблетки наверху 25.09.2026,
    // Alex TG). Пункт «радио по этой» из меню долгого нажатия убран как
    // дубль (план упрощения, п.1, Alex TG 15.09.2026).
    await tester.tap(find.byKey(const ValueKey('mode_similar')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('похожее по звуку'), findsOneWidget);
    expect(player.similarTailCalls, hasLength(1));
    expect(player.similarTailCalls.single, hasLength(2)); // seed исключён, остаются два других
    // Главное: на нажатие сервер вообще не трогали (раньше тут висели 8 секунд).
    expect(api.streamOrderCalls, 0);
    expect(api.trackVectorsCalls, 0);
    await db.close();
  });

  testWidgets('много кандидатов — первый кусок быстрый, остальное дозагружается фоном', (tester) async {
    // Alex TG 14.09.2026: «подбирать кусочками... прослушал первые — ещё
    // подгружает» — на реальном телефоне поход в базу за 500 отпечатками
    // занимал 8+ секунд. Первый кусок (80) должен уйти в setSimilarTail
    // сразу, а остаток — отдельным вызовом extendSimilarTail, без ожидания
    // видимого в UI.
    //
    // 91 трек, каждый — свой орт (одна единица на своей позиции в 91-мерном
    // векторе) — попарный косинус между ЛЮБЫМИ двумя из них ровно 0, то есть
    // ниже порога дубликата (0.98), КАКОЙ БЫ из них Поток ни поставил играть
    // первым (не контролируем это напрямую — весовой шаффл, см.
    // local_taste.dart) — тест не должен зависеть от того, какой именно
    // трек окажется seed.
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    const total = 91;
    for (var i = 0; i < total; i++) {
      final vec = List<double>.filled(total, 0)..[i] = 1;
      await db.upsertDownloaded(DownloadedTrack(
        id: 't$i', title: 'T$i', artist: 'Artist$i', path: '/tmp/t$i', bytes: 1, addedAt: i + 1,
      ));
      await db.setTrackVector('t$i', _vecBytes(vec));
    }
    final player = _FakePlayerController();

    await tester.pumpWidget(await _appWith(_ServerMustNotBeAsked(), db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('mode_similar')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(player.similarTailCalls, hasLength(1));
    expect(player.similarTailCalls.single.length, lessThanOrEqualTo(80));

    // Фоновая дозагрузка — отдельный microtask/await, не завязана на кадр UI.
    // Не pumpAndSettle: фон плеера (_bg) крутится бесконечной анимацией,
    // пока играет трек — pumpAndSettle тогда никогда не «уляжется» (см. тот
    // же приём в остальных тестах этого файла).
    await tester.pump(const Duration(milliseconds: 500));

    expect(player.extendCalls, hasLength(1));
    expect(player.extendCalls.single, isNotEmpty);
    // Вместе первый кусок и дозагрузка покрывают всех кандидатов, кроме
    // того единственного трека, что играет (seed в кандидаты не входит).
    final allIds = {
      for (final t in player.similarTailCalls.single) t.id,
      for (final t in player.extendCalls.single) t.id,
    };
    expect(allIds.length, total - 1);
    await db.close();
  });

  testWidgets('нет отпечатка у песни ни на телефоне, ни у сервера — честный тост, радио не включается', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(id: 'a', title: 'A', artist: 'X', path: '/tmp/a', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'b', title: 'B', artist: 'Y', path: '/tmp/b', bytes: 1, addedAt: 2));
    final api = _ServerKnowsNoFingerprint();
    final player = _FakePlayerController();

    await tester.pumpWidget(await _appWith(api, db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('mode_similar')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('нет звукового отпечатка'), findsOneWidget);
    expect(player.similarTailCalls, isEmpty);
    // Первым делом спросили сервер про ОДНУ песню (seed), а не про все.
    expect(api.trackVectorsCalls.first, hasLength(1));
    await db.close();
  });

  testWidgets('у самой песни нет отпечатка на телефоне, сервер отдаёт — подтягиваем один и собираем радио', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    for (final (i, id) in ['a', 'b', 'c', 'd'].indexed) {
      await db.upsertDownloaded(DownloadedTrack(
        id: id, title: id.toUpperCase(), artist: 'Artist$i', path: '/tmp/$id', bytes: 1, addedAt: i + 1,
      ));
    }
    // У a, b, c отпечатки на телефоне есть (углы 0°/30°/60° — разные, не
    // «тот же трек» по порогу 0.98); у d — нет, его отдаст сервер.
    await db.setTrackVector('a', _vecBytes([1, 0]));
    await db.setTrackVector('b', _vecBytes([0.866, 0.5]));
    await db.setTrackVector('c', _vecBytes([0.5, 0.866]));
    final api = _ServerGivesVectors({'d': _vecBytes([0.7, 0.7])});
    final player = _FakePlayerController();

    await tester.pumpWidget(await _appWith(api, db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Радио включаем именно с «d» — у неё на телефоне отпечатка нет.
    player.now.value = const NowPlaying(id: 'd', title: 'D', artist: 'Artist3');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('mode_similar')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.trackVectorsCalls.first, ['d']); // подтянули только один недостающий
    expect(find.textContaining('похожее по звуку'), findsOneWidget);
    expect(player.similarTailCalls, hasLength(1));
    expect(player.similarTailCalls.single, hasLength(3)); // a, b, c
    expect(await db.trackVector('d'), isNotNull); // и он теперь лежит на телефоне
    await db.close();
  });
}

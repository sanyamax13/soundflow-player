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
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/cover_art.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _NetworkDownApi extends Api {
  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    throw DioException(requestOptions: RequestOptions(path: '/v1/stream/order'));
  }
}

class _NoFingerprintApi extends Api {
  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async =>
      (ids: candidateIds, reordered: false);
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

  testWidgets('сеть недоступна + есть локальные отпечатки — фолбэк собирает похожее', (tester) async {
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

    await tester.pumpWidget(await _appWith(_NetworkDownApi(), db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Кнопка радио живёт в оверлее _actionsOverlay, который открывается
    // долгим тапом по обложке (player_view.dart `onLongPress: _openMenu` на
    // GestureDetector внутри _coverArea) — сам пункт меню — Text('радио\nпо
    // этой').
    await tester.longPress(find.byType(CoverArt));
    await tester.pump();
    await tester.tap(find.text('радио\nпо этой'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Сервера нет'), findsOneWidget);
    expect(player.similarTailCalls, hasLength(1));
    expect(player.similarTailCalls.single, hasLength(2)); // b исключён как seed, остаются a и c
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

    await tester.pumpWidget(await _appWith(_NetworkDownApi(), db, player: player));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.longPress(find.byType(CoverArt));
    await tester.pump();
    await tester.tap(find.text('радио\nпо этой'));
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

  testWidgets('нет отпечатка у seed (reordered:false) — фолбэк НЕ включается, обычный тост', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(id: 'a', title: 'A', artist: 'X', path: '/tmp/a', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'b', title: 'B', artist: 'Y', path: '/tmp/b', bytes: 1, addedAt: 2));

    await tester.pumpWidget(await _appWith(_NoFingerprintApi(), db));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.longPress(find.byType(CoverArt));
    await tester.pump();
    await tester.tap(find.text('радио\nпо этой'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('нет звукового отпечатка'), findsOneWidget);
    await db.close();
  });
}

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
  @override
  Future<void> setSimilarTail(List<NowPlaying> tail) async {
    similarTailCalls.add(tail);
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
    await db.setTrackVector('a', _vecBytes([1, 0]));
    await db.setTrackVector('b', _vecBytes([0.9, 0.1]));
    await db.setTrackVector('c', _vecBytes([0.8, 0.2]));
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

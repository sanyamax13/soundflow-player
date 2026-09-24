import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/auto_sync.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/data/sync_repo.dart';

/// AutoSync сам решает, КОГДА пробовать отправить накопленное (старт,
/// период, возврат в приложение, через несколько секунд после нового
/// события) — до этого файла ни одно из этих правил не было проверено
/// тестом (критик, Опус-ревью 24.09.2026, пункт 2). Реальные SyncRepo/
/// DownloadsRepo/SyncOffer уже проверены каждый по отдельности
/// (sync_repo_test.dart, sync_offer_test.dart, downloads_repo_test.dart) —
/// здесь фейкается не сеть, а сами эти три зависимости целиком: важно
/// только, КОГДА и СКОЛЬКО раз AutoSync их дёргает, не что внутри них.
class _RecSync extends SyncRepo {
  _RecSync(super.api, super.db);
  final calls = <String>[];
  bool failSync = false;

  @override
  Future<({int sent, int pending})> sync({int musicBytes = 0}) async {
    calls.add('sync');
    if (failSync) throw Exception('нет связи');
    return (sent: 0, pending: 0);
  }

  @override
  Future<void> reportFavorites(List<Map<String, String>> tracks) async {
    calls.add('reportFavorites');
  }
}

class _RecDownloads extends DownloadsRepo {
  _RecDownloads(super.api, super.db, [super.sync]);
  final calls = <String>[];
  bool failFavorites = false;

  @override
  Future<({int count, int bytes})> stats() async {
    calls.add('stats');
    return (count: 0, bytes: 0);
  }

  @override
  Future<List<Map<String, String>>> favoritesForReport() async {
    calls.add('favoritesForReport');
    if (failFavorites) throw Exception('нет связи');
    return [];
  }

  @override
  Future<void> returnFilesToPc() async {
    calls.add('returnFilesToPc');
  }

  @override
  Future<void> reportInventory() async {
    calls.add('reportInventory');
  }
}

class _RecOffer extends SyncOffer {
  _RecOffer(super.downloads);
  final calls = <String>[];

  @override
  Future<void> refresh({bool announce = true}) async {
    calls.add('refresh');
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  Future<Db> freshDb() =>
      Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  ({_RecSync sync, _RecDownloads downloads, _RecOffer offer, AutoSync auto, Db db})
  rig(Db db) {
    final api = Api();
    final sync = _RecSync(api, db);
    final downloads = _RecDownloads(api, db, sync);
    final offer = _RecOffer(downloads);
    return (
      sync: sync,
      downloads: downloads,
      offer: offer,
      auto: AutoSync(sync, downloads, offer),
      db: db,
    );
  }

  testWidgets('старт: пробует синк через несколько секунд, не раньше', (tester) async {
    final r = rig(await freshDb());
    r.auto.start();

    await tester.pump(const Duration(seconds: 3)); // меньше startupDelay (4с)
    expect(r.sync.calls, isEmpty, reason: 'ещё рано');

    await tester.pump(const Duration(seconds: 2)); // теперь прошло 5с
    expect(r.sync.calls, ['sync', 'reportFavorites']);
    expect(r.downloads.calls, containsAll(['stats', 'favoritesForReport', 'returnFilesToPc', 'reportInventory']));
    expect(r.offer.calls, ['refresh']);

    r.auto.dispose();
    await r.db.close();
  });

  testWidgets('дальше сам себя дёргает раз в период, без ручного нажатия', (tester) async {
    final r = rig(await freshDb());
    r.auto.start();
    await tester.pump(const Duration(seconds: 5)); // стартовый заход
    expect(r.sync.calls.where((c) => c == 'sync').length, 1);

    await tester.pump(const Duration(minutes: 3));
    expect(r.sync.calls.where((c) => c == 'sync').length, 2, reason: 'период — 3 минуты');

    r.auto.dispose();
    await r.db.close();
  });

  testWidgets('несколько событий подряд — один заход, не по одному на каждое', (tester) async {
    final r = rig(await freshDb());
    r.auto.start();
    await tester.pump(const Duration(seconds: 5)); // сняли стартовый заход с доски
    r.sync.calls.clear();

    // SyncRepo.onEnqueued зовётся так каждый раз, когда что-то легло в очередь
    // (лайк, удаление…) — пачка из нескольких должна дать ОДИН синк, не пять.
    for (var i = 0; i < 5; i++) {
      r.sync.onEnqueued?.call();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(r.sync.calls, isEmpty, reason: 'debounce (5с) ещё не истёк');
    await tester.pump(const Duration(seconds: 5));
    expect(r.sync.calls.where((c) => c == 'sync').length, 1, reason: 'пять событий подряд — один синк, не пять');

    r.auto.dispose();
    await r.db.close();
  });

  testWidgets('вернулись в приложение из фона — тоже повод синкнуться', (tester) async {
    final r = rig(await freshDb());
    r.auto.start();
    await tester.pump(const Duration(seconds: 5));
    r.sync.calls.clear();

    r.auto.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(r.sync.calls, isEmpty, reason: 'уход в фон сам по себе не повод');

    r.auto.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(r.sync.calls, contains('sync'));

    r.auto.dispose();
    await r.db.close();
  });

  testWidgets('нет связи — событие остаётся в очереди, остальные шаги не рвутся', (tester) async {
    final r = rig(await freshDb());
    r.sync.failSync = true;
    r.auto.start();

    await tester.pump(const Duration(seconds: 5));
    // sync() упал — но избранное/предложение с ПК/возврат файлов всё равно
    // должны были попытаться (Alex не должен терять их из-за одной ошибки).
    expect(r.downloads.calls, containsAll(['favoritesForReport', 'returnFilesToPc', 'reportInventory']));
    expect(r.offer.calls, ['refresh']);

    r.auto.dispose();
    await r.db.close();
  });

  testWidgets('dispose останавливает дальнейшие попытки', (tester) async {
    final r = rig(await freshDb());
    r.auto.start();
    await tester.pump(const Duration(seconds: 5));
    r.sync.calls.clear();

    r.auto.dispose();
    await tester.pump(const Duration(minutes: 5));
    expect(r.sync.calls, isEmpty);

    await r.db.close();
  });
}

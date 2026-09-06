import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'api.dart';
import 'db.dart';
import 'downloads_repo.dart';
import 'sync_repo.dart';

/// Фоновая синхронизация, когда приложение полностью закрыто (Android
/// WorkManager). `AutoSync` разгребает очередь, только пока приложение
/// открыто; это добивает случай «телефон дома, приложение не запускал».
///
/// Честно про ограничения (Alex предупреждён 06.09.2026): точный момент
/// выбирает сама Android. Минимальная периодичность — 15 минут, но под
/// энергосбережением задача может откладываться на час-два. Гарантии «ровно
/// как пришёл домой» нет — это ограничение ОС, не наше.
const _taskName = 'ru.soundflow.bgsync';
const _uniqueName = 'ru.soundflow.bgsync.periodic';

/// Точка входа фоновой задачи. Работает в отдельном изоляте, без дерева
/// виджетов — сервисы собираем заново.
@pragma('vm:entry-point')
void bgSyncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    Db? db;
    try {
      db = await Db.open();
      final api = Api();
      final sync = SyncRepo(api, db);
      if (await sync.pendingCount() == 0) return true;
      final downloads = DownloadsRepo(api, db, sync);
      final bytes = (await downloads.summary()).bytes;
      await sync.sync(musicBytes: bytes);
      return true;
    } catch (_) {
      // Нет связи с сервером / что-то пошло не так — события остаются в
      // очереди, WorkManager перезапустит задачу по своему графику.
      return false;
    } finally {
      await db?.close();
    }
  });
}

/// Включить фоновую синхронизацию. Только Android — на iOS у WorkManager
/// другой, куда более урезанный механизм, а приложение всё равно под
/// телефон Alex. Задача периодическая, раз в ~15 минут, только по Wi-Fi
/// (`unmetered`) и не на низком заряде. `keep` — если задача уже
/// зарегистрирована прошлым запуском, не пересоздаём.
Future<void> initBackgroundSync() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(bgSyncCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _uniqueName,
    _taskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(
      networkType: NetworkType.unmetered,
      requiresBatteryNotLow: true,
    ),
    // Уже зарегистрирована прошлым запуском — обновить спецификацию, не
    // пересоздавать (сохраняет тайминг, не перебивает идущего воркера).
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

import 'dart:convert';
import 'dart:math';

import 'api.dart';
import 'db.dart';

/// Очередь событий телефона и выгрузка их на сервер (этап 3 плана).
///
/// События (лайк, удаление, что слушал) копятся в SQLite и живут офлайн.
/// Дома по кнопке уходят на сервер батчем. Дедуп по uuid — один и тот же
/// раз сервер повторно не примет, поэтому потеря связи посреди отправки
/// не двоит события.
class SyncRepo {
  SyncRepo(this._api, this._db);

  final Api _api;
  final Db _db;

  static const _kDeviceId = 'device_id';
  static const _kLastSync = 'last_sync_at';

  final _rnd = Random.secure();

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Постоянный id этого телефона (генерируется один раз, хранится в kv).
  Future<String> deviceId() async {
    var id = await _db.kvGet(_kDeviceId);
    if (id == null) {
      id = _uuid();
      await _db.kvSet(_kDeviceId, id);
    }
    return id;
  }

  Future<DateTime?> lastSyncAt() async {
    final s = await _db.kvGet(_kLastSync);
    return s == null ? null : DateTime.tryParse(s);
  }

  /// Записать событие в очередь. Уйдёт на сервер при следующей синхронизации.
  Future<void> record(String kind, {String trackId = '', Map<String, Object?>? payload}) =>
      _db.enqueueEvent(
        uuid: _uuid(),
        kind: kind,
        trackId: trackId,
        payload: jsonEncode(payload ?? const <String, Object?>{}),
        clientTs: DateTime.now().millisecondsSinceEpoch,
      );

  Future<int> pendingCount() => _db.pendingCount();

  /// Отправить накопленное на сервер. Возвращает, сколько событий сервер
  /// принял как новые и сколько осталось в очереди. Бросает исключение,
  /// если сервер недоступен.
  Future<({int sent, int pending})> sync({int musicBytes = 0}) async {
    final pending = await _db.pendingEvents();
    if (pending.isEmpty) {
      await _db.kvSet(_kLastSync, DateTime.now().toIso8601String());
      return (sent: 0, pending: 0);
    }

    final events = [
      for (final e in pending)
        {
          'uuid': e['uuid'],
          'kind': e['kind'],
          'track_id': e['track_id'],
          'payload': jsonDecode('${e['payload'] ?? '{}'}'),
          'ts': e['client_ts'],
        }
    ];

    final accepted = await _api.postSyncEvents(
      deviceId: await deviceId(),
      musicBytes: musicBytes,
      events: events,
    );

    // Весь батч гарантированно на сервере (транзакция на той стороне —
    // всё или ничего). Помечаем отправленным всё, что слали.
    final batch = [for (final e in pending) e['uuid'] as String];
    await _db.markSynced(batch);
    await _db.kvSet(_kLastSync, DateTime.now().toIso8601String());

    return (sent: accepted.length, pending: await _db.pendingCount());
  }
}

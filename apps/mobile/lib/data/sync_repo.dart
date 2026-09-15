import 'dart:convert';
import 'dart:math';

import '../core/device_info.dart';
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
  static const _kTasteHash = 'taste_centroids_hash';
  static const _kTasteData = 'taste_centroids';

  final _rnd = Random.secure();

  /// Дёргается после каждого нового события — [AutoSync] вешает сюда
  /// отложенную попытку отправки (06.09.2026).
  void Function()? onEnqueued;

  /// Чтобы ручная кнопка и авто-синк не слали один и тот же батч дважды.
  bool _inFlight = false;

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

  /// Записать событие в очередь. Уйдёт на сервер при следующей синхронизации
  /// (авто — как появится связь, либо руками кнопкой).
  Future<void> record(String kind, {String trackId = '', Map<String, Object?>? payload}) async {
    await _db.enqueueEvent(
      uuid: _uuid(),
      kind: kind,
      trackId: trackId,
      payload: jsonEncode(payload ?? const <String, Object?>{}),
      clientTs: DateTime.now().millisecondsSinceEpoch,
    );
    onEnqueued?.call();
  }

  Future<int> pendingCount() => _db.pendingCount();

  /// Отправить накопленное на сервер. Возвращает, сколько событий сервер
  /// принял как новые и сколько осталось в очереди. Бросает исключение,
  /// если сервер недоступен.
  Future<({int sent, int pending})> sync({int musicBytes = 0}) async {
    if (_inFlight) return (sent: 0, pending: await _db.pendingCount());
    _inFlight = true;
    try {
      return await _syncOnce(musicBytes);
    } finally {
      _inFlight = false;
    }
  }

  Future<({int sent, int pending})> _syncOnce(int musicBytes) async {
    final pending = await _db.pendingEvents();
    if (pending.isEmpty) {
      await _db.kvSet(_kLastSync, DateTime.now().toIso8601String());
      await _pullTasteCentroidsIfChanged();
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

    final dev = await DeviceInfo.read();
    final accepted = await _api.postSyncEvents(
      deviceId: await deviceId(),
      musicBytes: musicBytes,
      deviceName: dev.model,
      transport: dev.transport,
      events: events,
    );

    // Весь батч гарантированно на сервере (транзакция на той стороне —
    // всё или ничего). Помечаем отправленным всё, что слали.
    final batch = [for (final e in pending) e['uuid'] as String];
    await _db.markSynced(batch);
    await _db.kvSet(_kLastSync, DateTime.now().toIso8601String());
    await _pullTasteCentroidsIfChanged();

    return (sent: accepted.length, pending: await _db.pendingCount());
  }

  /// Отправить список залайканных на телефоне песен (Alex TG 15.09.2026) —
  /// узкий канал в обратную сторону от обычной синхронизации: сервер сам
  /// решает, чего из этого не хватает в его каталоге.
  Future<void> reportFavorites(List<Map<String, String>> tracks) =>
      _api.reportPhoneFavorites(tracks);

  /// Слепок вкуса — тянем только когда хэш на сервере разошёлся с тем, что
  /// уже сохранено (иначе при частых синках гоняли бы одни и те же
  /// центры лишний раз). Сеть недоступна/сервер старой версии — тихо
  /// пропускаем, следующий синк попробует снова.
  Future<void> _pullTasteCentroidsIfChanged() async {
    final serverHash = await _api.tasteCentroidsHash();
    if (serverHash == null) return;
    final localHash = await _db.kvGet(_kTasteHash);
    if (serverHash == localHash) return;
    final data = await _api.tasteCentroids();
    if (data == null) return;
    await _db.kvSet(_kTasteHash, data.hash);
    await _db.kvSet(
      _kTasteData,
      jsonEncode({
        'long_term': [for (final v in data.longTerm) base64Encode(v)],
        'recent': [for (final v in data.recent) base64Encode(v)],
      }),
    );
  }
}

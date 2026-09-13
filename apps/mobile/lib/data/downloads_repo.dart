import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import 'api.dart';
import 'db.dart';
import 'sync_repo.dart';

/// Скачивание треков с сервера в память телефона и учёт скачанного —
/// список «Моя музыка». Правила 50 ГБ, автоподкачка по Wi-Fi — потом.
///
/// Действия пользователя (скачал / удалил / в избранное) заодно кладутся
/// в очередь событий [SyncRepo], чтобы дома уехать на сервер.
class DownloadsRepo {
  DownloadsRepo(this._api, this._db, [this._sync]);

  final Api _api;
  final Db _db;
  final SyncRepo? _sync;

  Future<Directory> _musicDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/music');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> _coversDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> localPath(String id) async => '${(await _musicDir()).path}/$id';

  Future<bool> isDownloaded(String id) async {
    final row = await _db.downloadedById(id);
    return row != null && File(row.path).existsSync();
  }

  /// Скачать один трек. Возвращает размер файла в байтах.
  Future<int> download(Map<String, dynamic> track) async {
    final id = '${track['id']}';
    final path = await localPath(id);
    await _api.downloadTrack(id, path);
    final size = await File(path).length();

    // Обложка — необязательно: нет ссылки или сайт с картинкой не ответил —
    // просто играем без неё, трек это не должно останавливать.
    String? coverPath;
    final coverUrl = '${track['cover_url'] ?? ''}';
    if (coverUrl.isNotEmpty) {
      try {
        final cp = '${(await _coversDir()).path}/$id.jpg';
        await _api.downloadCover(coverUrl, cp);
        coverPath = cp;
      } catch (_) {
        coverPath = null;
      }
    }

    await _db.upsertDownloaded(DownloadedTrack(
      id: id,
      title: '${track['title'] ?? id}',
      artist: '${track['artist'] ?? ''}',
      path: path,
      bytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      coverPath: coverPath,
      bitrateKbps: (track['bitrate_kbps'] as num?)?.toInt(),
      format: formatFromMime(track['mime_type'] as String?),
      durationSec: (track['duration_sec'] as num?)?.toInt(),
    ));
    await _sync?.record('download', trackId: id);
    // Был в избранном старого плеера — ставим сердечко (только добавляем).
    if (track['favorite'] == true) {
      await _db.setFavorite(id, true);
      await _sync?.record('like', trackId: id);
    }

    // Отпечаток — необязательная надстройка для офлайн-радио (см.
    // features/player/player_view.dart _radio()); нет сети/старая версия
    // сервера — молча пропускаем, попробует backfillVectors() при
    // следующем запуске.
    try {
      final vectors = await _api.trackVectors([id]);
      if (vectors[id] case final v?) {
        await _db.setTrackVector(id, v);
      }
    } catch (_) {}

    return size;
  }

  /// [reason] — почему убрали (см. player_view.dart, 05.09.2026: Alex
  /// попросил спрашивать причину, чтобы потом было видно, какие песни
  /// правда плохие, а какие просто не по вкусу). Необязательный — старые
  /// места вызова (свайп в «Моей музыке») пока без причины.
  Future<void> delete(String id, {String? reason}) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
      // В журнал «Убранные» — для статистики (сколько убрано, сколько места
      // освободилось, по причине). Заменяет «Корзину» (Alex TG 18689).
      await _db.addRemoved(
        id: id,
        title: row.title,
        artist: row.artist,
        bytes: row.bytes,
        reason: reason ?? '',
        removedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _db.deleteDownloaded(id);
    await _sync?.record('delete',
        trackId: id, payload: reason == null ? null : {'reason': reason});
  }

  /// Стереть скачанный трек ТОЛЬКО на телефоне — без события на сервер и без
  /// журнала «Убранные». Для плана ручной синхронизации: убрать трек решил
  /// сам сервер (окно на компе), эхо-событие «delete» не нужно и опасно —
  /// обычное удаление на сервере метит трек «больше не качать» и стирает
  /// файл на компе.
  Future<void> _deleteLocalOnly(String id) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownloaded(id);
  }

  /// Поправить нечитаемые теги скачанной песни (кнопка «Исправить имя»,
  /// Alex TG 18693). Заодно кладём событие — сервер тоже узнает.
  Future<void> rename(String id,
      {required String artist, required String title}) async {
    await _db.updateTags(id, artist: artist, title: title);
    await _sync?.record('rename',
        trackId: id, payload: {'artist': artist, 'title': title});
  }

  // --- Убранные ---

  Future<List<Map<String, Object?>>> removedList() => _db.removedList();
  Future<({int count, int bytes})> removedTotals() => _db.removedTotals();
  Future<Map<String, ({int count, int bytes})>> removedByReason() =>
      _db.removedByReason();
  Future<void> removedClear() => _db.removedClear();

  /// Скачать заново то, что раньше убрали (кнопка в «Убранных»). Файл на
  /// сервере мог остаться — пробуем прямую загрузку по id; получилось —
  /// убираем из журнала.
  Future<void> redownload(String id, {required String title, required String artist}) async {
    await download({'id': id, 'title': title, 'artist': artist});
    await _db.removedForget(id);
  }

  /// Докачать обложки уже скачанным трекам, у которых их пока нет — чтобы
  /// показывались сразу с диска, без подгрузки по сети каждый раз (05.09.2026,
  /// просьба Alex после того как обложки заработали: "надо сделать всё
  /// офлайн, чтобы обложки не подгружались"). Вызывается фоном при старте
  /// приложения (main.dart) — не мешает пользоваться, пока идёт; не нашлась
  /// обложка сейчас — трек просто остаётся без нее до следующего запуска
  /// (сервер может позже сам найти через другой источник, см. этап 24).
  Future<void> backfillCovers({int concurrency = 5}) async {
    final rows = await _db.allDownloaded();
    final pending = [
      for (final t in rows)
        if (t.coverPath == null || !File(t.coverPath!).existsSync()) t,
    ];
    for (var i = 0; i < pending.length; i += concurrency) {
      await Future.wait(pending.skip(i).take(concurrency).map(_fetchCoverFor));
    }
  }

  Future<void> _fetchCoverFor(DownloadedTrack t) async {
    try {
      final cp = '${(await _coversDir()).path}/${t.id}.jpg';
      await _api.downloadCover(coverUrlFor(t.id), cp);
      await _db.upsertDownloaded(DownloadedTrack(
        id: t.id,
        title: t.title,
        artist: t.artist,
        path: t.path,
        bytes: t.bytes,
        addedAt: t.addedAt,
        favorite: t.favorite,
        coverPath: cp,
        bitrateKbps: t.bitrateKbps,
        format: t.format,
        durationSec: t.durationSec,
      ));
    } catch (_) {
      // не нашлась — не страшно, попробуем в другой раз при следующем запуске
    }
  }

  Future<void> setFavorite(String id, bool value) async {
    await _db.setFavorite(id, value);
    await _sync?.record(value ? 'like' : 'unlike', trackId: id);
  }

  /// Плеер узнал длительность играющего файла — записываем её и оценку
  /// битрейта (размер·8/длительность, привязка к обычным ступеням), если
  /// характеристик ещё нет. Так они появляются у всех песен, что слушали,
  /// без запроса к серверу (Alex TG 18704).
  Future<void> noteFileMeta(String id, Duration total) async {
    final sec = total.inSeconds;
    if (sec <= 0) return;
    final row = await _db.downloadedById(id);
    if (row == null || (row.durationSec ?? 0) > 0) return;
    int? kbps;
    if (row.bytes > 0) {
      final raw = (row.bytes * 8 / 1000 / sec).round();
      const tiers = [64, 96, 128, 160, 192, 224, 256, 320];
      final near = tiers.firstWhere((t) => (t - raw).abs() <= 24, orElse: () => -1);
      kbps = near > 0 ? near : (raw / 16).round() * 16;
    }
    await _db.updateMeta(id, durationSec: sec, bitrateKbps: kbps);
  }

  /// Дописать характеристики (битрейт/формат/длительность) уже скачанным
  /// песням, у которых их нет — они появились в ответе сервера позже
  /// (Alex TG 18704). Один запрос всего каталога, сверка по id. Фоном при
  /// старте, как backfillCovers.
  Future<void> backfillMeta() async {
    final need = [
      for (final t in await _db.allDownloaded())
        if ((t.format ?? '').isEmpty && (t.bitrateKbps ?? 0) == 0 && (t.durationSec ?? 0) == 0)
          t.id,
    ];
    if (need.isEmpty) return;
    List<Map<String, dynamic>> catalog;
    try {
      catalog = await _api.tracks(limit: 10000);
    } catch (_) {
      return; // нет сети — попробуем в следующий раз
    }
    final byId = {for (final m in catalog) '${m['id']}': m};
    for (final id in need) {
      final m = byId[id];
      if (m == null) continue;
      final fmt = formatFromMime(m['mime_type'] as String?);
      final br = (m['bitrate_kbps'] as num?)?.toInt();
      final dur = (m['duration_sec'] as num?)?.toInt();
      if ((fmt ?? '').isEmpty && (br ?? 0) == 0 && (dur ?? 0) == 0) continue;
      await _db.updateMeta(id, bitrateKbps: br, format: fmt, durationSec: dur);
    }
  }

  /// Докачать отпечатки уже скачанным трекам, у которых их ещё нет — для
  /// офлайн-радио (docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md
  /// §4.4). Пачками по 200 (одна ручка принимает список, не по одному
  /// треку). Фоном при старте, как backfillCovers/backfillMeta.
  Future<void> backfillVectors() async {
    final all = await _db.allDownloaded();
    final have = await _db.trackVectorsFor([for (final t in all) t.id]);
    final need = [for (final t in all) if (!have.containsKey(t.id)) t.id];
    if (need.isEmpty) return;
    const chunk = 200;
    for (var i = 0; i < need.length; i += chunk) {
      final part = need.sublist(i, i + chunk > need.length ? need.length : i + chunk);
      Map<String, Uint8List> vectors;
      try {
        vectors = await _api.trackVectors(part);
      } catch (_) {
        return; // нет сети — попробуем в следующий раз
      }
      for (final entry in vectors.entries) {
        await _db.setTrackVector(entry.key, entry.value);
      }
    }
  }

  /// В избранном ли скачанный трек (для сердечка в плеере).
  Future<bool> favorite(String id) async => (await _db.downloadedById(id))?.favorite ?? false;

  Future<List<DownloadedTrack>> list({bool onlyFavorite = false}) =>
      _db.allDownloaded(onlyFavorite: onlyFavorite);

  /// [covers] — сколько из скачанных песен уже с обложкой на диске (просьба
  /// Alex 05.09.2026: видеть счётчик обложек рядом со счётчиком песен, а не
  /// гадать по логам сервера).
  Future<({int count, int bytes, int covers})> summary() async {
    final all = await _db.allDownloaded();
    final covers = all.where((t) => t.coverPath != null && File(t.coverPath!).existsSync()).length;
    return (count: all.length, bytes: await _db.totalBytes(), covers: covers);
  }

  /// Поиск по каталогу сервера (что уже скачано на домашний компьютер).
  Future<List<Map<String, dynamic>>> searchCatalog(String q) => _api.searchCatalog(q);

  /// «Докачать ещё»: спрашивает сервер, что из библиотеки ещё не скачано
  /// (избранное — вперёд), и качает порцию по budgetBytes (по умолчанию
  /// 20 ГБ). onProgress зовётся после каждого трека: (сколько скачано,
  /// сколько всего в порции, название текущего). Останавливаем скачивание
  /// без сети или другой ошибки — то, что успело, уже в «Моей музыке».
  Future<({int downloaded, int bytes, int failed})> downloadMore({
    int budgetBytes = 20 * 1024 * 1024 * 1024,
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final excludeIds = (await _db.allDownloaded()).map((t) => t.id).toList();
    final batch = await _api.nextLibraryBatch(excludeIds: excludeIds, budgetBytes: budgetBytes);
    final total = batch.tracks.length;
    // id телефона — чтобы слать прогресс на сервер (окно «Устройства» на
    // компьютере). Нет SyncRepo — просто не шлём, скачивание идёт как раньше.
    final devId = await _sync?.deviceId();
    var done = 0;
    var bytes = 0;
    var failed = 0;
    for (final track in batch.tracks) {
      final label = '${track['artist'] ?? ''} — ${track['title'] ?? ''}';
      onProgress?.call(done, total, label);
      if (devId != null) {
        await _api.syncProgress(
            deviceId: devId, done: done, total: total, current: label, active: true);
      }
      try {
        bytes += await download(track);
      } catch (_) {
        // Один плохой трек (сеть моргнула, файл пропал) не должен рвать
        // всю порцию — пробуем следующий, недокачанное подберётся в
        // следующий раз (его id не попадёт в excludeIds).
        failed++;
      }
      done++;
    }
    onProgress?.call(done, total, '');
    if (devId != null) {
      await _api.syncProgress(
          deviceId: devId, done: done, total: total, current: '', active: false);
    }
    return (downloaded: done - failed, bytes: bytes, failed: failed);
  }

  /// Выполнить план ручной синхронизации, собранный Alex в окне на компе
  /// (кнопка «Синхронизировать» → галочки → «Далее», Alex TG 19000, 19002).
  /// Телефон только исполняет: качает отмеченное к добавлению, стирает
  /// отмеченное к удалению (локально, без события), потом отчитывается —
  /// сервер удаляет план. Плана нет — тихо выходим (0/0/0). Нет связи —
  /// бросит исключение вызывающему (AutoSync его глотает, подхватим позже).
  /// onProgress зовётся как в [downloadMore]: (сделано, всего, что сейчас).
  Future<({int added, int removed, int failed})> applyPendingPlan({
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final devId = await _sync?.deviceId();
    if (devId == null) return (added: 0, removed: 0, failed: 0);
    final plan = await _api.deviceSyncPlan(devId);
    if (plan == null) return (added: 0, removed: 0, failed: 0);

    final total = plan.add.length + plan.remove.length;
    var done = 0;
    var added = 0;
    var removed = 0;
    var failed = 0;

    for (final track in plan.add) {
      final label = '${track['artist'] ?? ''} — ${track['title'] ?? ''}';
      onProgress?.call(done, total, label);
      await _api.syncProgress(
          deviceId: devId, done: done, total: total, current: label, active: true);
      try {
        final id = '${track['id']}';
        if (!await isDownloaded(id)) {
          await download(track);
          added++;
        }
      } catch (_) {
        // Один плохой трек не рвёт весь план — недокачанное останется в
        // плане до ack и подберётся в следующий заход.
        failed++;
      }
      done++;
    }

    for (final id in plan.remove) {
      onProgress?.call(done, total, '');
      try {
        await _deleteLocalOnly(id);
        removed++;
      } catch (_) {
        failed++;
      }
      done++;
    }

    onProgress?.call(done, total, '');
    await _api.syncProgress(
        deviceId: devId, done: done, total: total, current: '', active: false);

    // Отчитались — сервер уберёт план. Не вышло (сеть моргнула) — план
    // останется, подхватим позже; уже скачанное пропускается (isDownloaded).
    try {
      await _api.ackSyncPlan(devId);
    } catch (_) {}

    return (added: added, removed: removed, failed: failed);
  }

  /// Заказать трек на сервере. Возвращает ответ каталога:
  /// {track_id, created, source, quality_tier}. Бросает [AcquireException].
  Future<Map<String, dynamic>> acquireOnServer({
    required String artist,
    required String title,
    int durationSec = 0,
  }) =>
      _api.acquireTrack(artist: artist, title: title, durationSec: durationSec);
}

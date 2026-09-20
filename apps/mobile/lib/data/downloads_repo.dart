import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/app_log.dart';
import '../core/config.dart';
import 'api.dart';
import 'db.dart';
import 'sync_repo.dart';

/// Флажок «остановить скачивание» для [DownloadsRepo.applyPendingPlan] — кнопка
/// «Стоп» на карточке синхронизации (Опус-ревью телефона 14.09.2026, пункт 7:
/// раньше начатую порцию было нельзя прервать). Проверяется между треками —
/// текущий докачивается до конца, следующий уже не начинается.
class DownloadCancelToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}

/// Что ждёт телефон по плану с компьютера: сколько песен скачать (и сколько
/// это весит) и сколько стереть. Считается только по тому, что ещё не сделано
/// на этом телефоне.
class PlanPreview {
  const PlanPreview({this.addCount = 0, this.addBytes = 0, this.removeCount = 0});

  static const empty = PlanPreview();

  final int addCount;
  final int addBytes;
  final int removeCount;

  bool get isEmpty => addCount == 0 && removeCount == 0;

  /// Отпечаток предложения — чтобы одно и то же не объявлять по кругу.
  String get signature => '$addCount/$addBytes/$removeCount';
}

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

  /// Залайканные на телефоне песни, для отправки на сервер (Alex TG
  /// 15.09.2026) — сервер сам сверит со своим каталогом.
  Future<List<Map<String, String>>> favoritesForReport() async {
    final rows = await _db.allDownloaded(onlyFavorite: true);
    return [for (final r in rows) {'artist': r.artist, 'title': r.title}];
  }

  /// Полный сброс — «как первый раз установил» (Alex TG 15.09.2026): стирает
  /// все скачанные файлы и обложки на телефоне + всю базу (лайки, историю,
  /// очередь событий). Адрес сервера и id телефона сохраняются — см.
  /// Db.fullReset(). Необратимо, вызывающий экран должен спросить подтверждение.
  Future<void> fullReset() async {
    final music = await _musicDir();
    if (music.existsSync()) music.deleteSync(recursive: true);
    final covers = await _coversDir();
    if (covers.existsSync()) covers.deleteSync(recursive: true);
    await _db.fullReset();
  }

  Future<bool> isDownloaded(String id) async {
    final row = await _db.downloadedById(id);
    return row != null && File(row.path).existsSync();
  }

  /// Скачать один трек. Возвращает размер файла в байтах.
  Future<int> download(Map<String, dynamic> track) async {
    final id = '${track['id']}';
    final path = await localPath(id);
    try {
      await _api.downloadTrack(id, path);
    } catch (_) {
      // Оборвалось посреди файла — недокачанный обрубок не оставляем.
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      rethrow;
    }
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
  ///
  /// Журнала «Убранные» на телефоне больше нет (Alex TG 19943, 19.09.2026:
  /// «убранные только в программе на сервере, плеер захламляется»): что убрали,
  /// знает программа на компьютере — по событию «delete» ниже.
  Future<void> delete(String id, {String? reason}) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownloaded(id);
    await _sync?.record('delete',
        trackId: id, payload: reason == null ? null : {'reason': reason});
  }

  /// Стереть скачанный трек ТОЛЬКО на телефоне — без события на сервер. Для
  /// плана ручной синхронизации: убрать трек решил сам сервер (окно на
  /// компе), эхо-событие «delete» не нужно и опасно —
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
  /// треку). Фоном при старте, как backfillCovers/backfillMeta, и ещё когда
  /// радио не нашло отпечаток у песни (player_view.dart _radio).
  ///
  /// Принцип Alex (TG 19.09.2026): сервер отпечатки считает и ОТДАЁТ
  /// телефону, дальше телефон работает сам — радио на нажатие сервер не
  /// спрашивает, поэтому дыры в доставке отпечатков надо закрывать здесь.
  /// Одновременно идёт не больше одного прогона (второй вызов ждёт первый).
  /// В журнал пишется, сколько не хватало и сколько докачалось — чтобы по
  /// записям с телефона было видно, где именно дыра: связи не было, или
  /// сервер этих отпечатков не отдал (тогда `got` меньше `need`, а
  /// `offline=false`).
  Future<void> backfillVectors() =>
      _vectorBackfill ??= _backfillVectors().whenComplete(() => _vectorBackfill = null);

  Future<void>? _vectorBackfill;

  Future<void> _backfillVectors() async {
    try {
      final all = await _db.allDownloaded();
      final have = await _db.trackVectorsFor([for (final t in all) t.id]);
      final need = [for (final t in all) if (!have.containsKey(t.id)) t.id];
      if (need.isEmpty) return;
      var got = 0;
      var offline = false;
      const chunk = 200;
      for (var i = 0; i < need.length; i += chunk) {
        final part = need.sublist(i, i + chunk > need.length ? need.length : i + chunk);
        Map<String, Uint8List> vectors;
        try {
          vectors = await _api.trackVectors(part);
        } catch (_) {
          offline = true; // нет сети — попробуем в следующий раз
          break;
        }
        for (final entry in vectors.entries) {
          await _db.setTrackVector(entry.key, entry.value);
          got++;
        }
      }
      // await, не unawaited: прогон и так идёт в фоне (вызывающие его не
      // ждут), а так запись в журнал закончена к моменту, когда прогон
      // считается завершённым — иначе тест удаляет папку под открытым файлом.
      await AppLog.event('vectors_backfill', {'need': need.length, 'got': got, 'offline': offline});
    } catch (_) {
      // Фоновая докачка не должна ронять ни приложение, ни тест.
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

  /// Что ждёт этот телефон по плану с компьютера — только смотрим, ничего не
  /// качаем и не стираем (Alex TG 20167: «не автоматически, а с вопросом»).
  /// Считаем лишь то, что реально надо сделать здесь: уже скачанное и уже
  /// стёртое в счёт не идёт. Если по плану на этом телефоне делать нечего —
  /// план тихо закрывается, чтобы не висел. Нет связи — бросит исключение.
  Future<PlanPreview> previewPlan() async {
    final devId = await _sync?.deviceId();
    if (devId == null) return PlanPreview.empty;
    final plan = await _api.deviceSyncPlan(devId);
    if (plan == null) return PlanPreview.empty;
    final todo = await _todo(plan.add, plan.remove);
    if (todo.add.isEmpty && todo.remove.isEmpty) {
      try {
        await _api.ackSyncPlan(devId);
      } catch (_) {}
      return PlanPreview.empty;
    }
    var bytes = 0;
    for (final t in todo.add) {
      bytes += (t['size_bytes'] as num?)?.toInt() ?? 0;
    }
    return PlanPreview(
      addCount: todo.add.length,
      addBytes: bytes,
      removeCount: todo.remove.length,
    );
  }

  /// Из плана — только то, что на этом телефоне ещё не сделано.
  Future<({List<Map<String, dynamic>> add, List<String> remove})> _todo(
    List<Map<String, dynamic>> add,
    List<String> remove,
  ) async {
    final a = <Map<String, dynamic>>[];
    for (final t in add) {
      if (!await isDownloaded('${t['id']}')) a.add(t);
    }
    final r = <String>[];
    for (final id in remove) {
      if (await _db.downloadedById(id) != null) r.add(id);
    }
    return (add: a, remove: r);
  }

  /// Выполнить план с компьютера (Alex TG 19000, 19002: выбор делает комп —
  /// кнопка в меню окна или «Синхронизировать» с галочками; телефон только
  /// исполняет). С 20.09.2026 — только по нажатию на телефоне («Скачать» /
  /// «Стереть»), а не само раз в 3 минуты: [adds] — качать отмеченное,
  /// [removes] — стирать отмеченное (локально, без события: убрать трек
  /// решил компьютер). [cancelToken] — кнопка «Стоп»: текущая песня
  /// докачивается, следующая не начинается.
  ///
  /// План закрывается на сервере, ТОЛЬКО когда по нему на этом телефоне
  /// больше нечего делать. Обрыв связи, «Стоп», не скачавшаяся песня — план
  /// остаётся, недоделанное предложится снова (раньше подтверждение слалось
  /// даже при ошибках, и недокачанные песни терялись; ревизия 20.09, п. 1в).
  /// Нет связи с сервером в самом начале — бросит исключение.
  Future<({int added, int removed, int failed, bool stopped})> applyPendingPlan({
    void Function(int done, int total, String title)? onProgress,
    DownloadCancelToken? cancelToken,
    bool adds = true,
    bool removes = true,
  }) async {
    const nothing = (added: 0, removed: 0, failed: 0, stopped: false);
    final devId = await _sync?.deviceId();
    if (devId == null) return nothing;
    final plan = await _api.deviceSyncPlan(devId);
    if (plan == null) return nothing;

    final todo = await _todo(plan.add, plan.remove);
    final addList = adds ? todo.add : const <Map<String, dynamic>>[];
    final removeList = removes ? todo.remove : const <String>[];
    final total = addList.length + removeList.length;
    var done = 0;
    var added = 0;
    var removed = 0;
    var failed = 0;
    var stopped = false;

    for (final track in addList) {
      if (cancelToken?.isCancelled ?? false) {
        stopped = true;
        break;
      }
      final label = '${track['artist'] ?? ''} — ${track['title'] ?? ''}';
      onProgress?.call(done, total, label);
      await _api.syncProgress(
          deviceId: devId, done: done, total: total, current: label, active: true);
      try {
        await download(track);
        added++;
      } catch (_) {
        // Одна плохая песня не рвёт весь план — она останется в плане и
        // предложится снова.
        failed++;
      }
      done++;
    }

    for (final id in removeList) {
      if (cancelToken?.isCancelled ?? false) {
        stopped = true;
        break;
      }
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

    // Закрываем план, только если на этом телефоне по нему всё сделано.
    try {
      final left = await _todo(plan.add, plan.remove);
      if (left.add.isEmpty && left.remove.isEmpty) await _api.ackSyncPlan(devId);
    } catch (_) {}

    return (added: added, removed: removed, failed: failed, stopped: stopped);
  }

  /// Файл трека пропал с диска, а запись о нём в базе — цела (см.
  /// `PlayerController.onMissingFile` — плеер словил недостающий файл в
  /// очереди, Alex TG 15.09.2026: «давай чинить, а не пропускать»).
  /// Перекачивает файл заново по уже известному пути; теги/битрейт/обложка
  /// в базе не трогаем — там всё верно, пропал только сам файл. Трека нет
  /// в базе вовсе (по-настоящему удалили) — бросаем исключение, вызывающий
  /// код (см. main.dart) просто оставит трек пропущенным.
  Future<void> redownloadMissingFile(String id) async {
    final row = await _db.downloadedById(id);
    if (row == null) {
      throw StateError('трек не найден в базе: $id');
    }
    await _api.downloadTrack(id, row.path);
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

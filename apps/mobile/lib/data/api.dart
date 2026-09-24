import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/config.dart';

/// Заказ трека не удался — текст уже человеческий, можно показывать как есть.
class AcquireException implements Exception {
  AcquireException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Слепок вкуса, пришедший с сервера — центры long_term+recent как «сырые»
/// векторы (little-endian float32, 8192 байта на каждый при VecDim=2048).
class TasteCentroids {
  const TasteCentroids({required this.hash, required this.longTerm, required this.recent});
  final String hash;
  final List<Uint8List> longTerm;
  final List<Uint8List> recent;
}

/// Клиент к серверу на Go. Входа нет — плеер личный, сервер в домашней сети.
class Api {
  Api({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? apiBase,
          connectTimeout: const Duration(seconds: 8),
        )) {
    apiBase = _dio.options.baseUrl; // держим глобальный адрес в согласии с клиентом
  }

  final Dio _dio;

  /// Только для тестов — подменить HTTP-адаптер фейковым.
  set debugAdapter(HttpClientAdapter a) => _dio.httpClientAdapter = a;

  /// Текущий адрес сервера, к которому обращается клиент.
  String get baseUrl => _dio.options.baseUrl;

  /// Сменить адрес сервера на лету (Профиль → «Адрес сервера»). Ввод
  /// приводится к `http://хост:порт`. Сохранение в базу — на вызывающем.
  void setBaseUrl(String raw) {
    final v = normalizeServerUrl(raw);
    _dio.options.baseUrl = v;
    apiBase = v;
  }

  /// Проверить сервер по адресу, НЕ переключаясь на него (кнопка «Проверить»
  /// в настройке адреса). true — ответил на /v1/health.
  static Future<bool> ping(String raw) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final r = await dio.get<Map<String, dynamic>>('/v1/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Готов ли компьютер к первому подключению (Alex TG 24.09.2026): «Найти
  /// сервер самому» нашёл ответивший адрес, но подключаться молча больше
  /// нельзя — на компьютере должны нажать «Подключить телефон». `null` —
  /// сервер не ответил на эту ручку вообще (например, старая версия
  /// программы без этой функции) — тогда вызывающий сам решает, как быть
  /// (обычно — как раньше, без подтверждения).
  static Future<({bool open, String name})?> pairingCheck(String raw) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final r = await dio.get<Map<String, dynamic>>('/api/pairing/check');
      final d = r.data;
      if (d == null) return null;
      return (open: d['open'] == true, name: (d['name'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Подтвердить первое подключение — компьютер ещё должен быть в открытом
  /// окне («Подключить телефон»), иначе false (окно истекло/закрыли).
  static Future<bool> pairingConfirm(String raw) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final r = await dio.post<Map<String, dynamic>>('/api/pairing/confirm');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Список треков с сервера.
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/tracks',
      queryParameters: limit == null ? null : {'limit': limit},
    );
    final list = (res.data?['tracks'] as List?) ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Поиск по каталогу сервера (что уже скачано на домашний компьютер).
  /// Пустой запрос — вернёт последние добавленные.
  Future<List<Map<String, dynamic>>> searchCatalog(String q) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/search',
      queryParameters: {'q': q},
    );
    final list = (res.data?['tracks'] as List?) ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Заказать трек: сервер ищет и качает его на домашний компьютер
  /// (Яндекс.Музыка → musify → торренты) и кладёт в каталог. Долгая
  /// операция — до нескольких минут. Бросает [AcquireException] с понятным
  /// текстом, если не вышло.
  Future<Map<String, dynamic>> acquireTrack({
    required String artist,
    required String title,
    int durationSec = 0,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/v1/tracks/acquire',
        data: {'artist': artist, 'title': title, 'duration_sec': durationSec},
        options: Options(receiveTimeout: const Duration(minutes: 10)),
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      final data = e.response?.data;
      final reason = (data is Map) ? '${data['reason'] ?? data['error'] ?? ''}' : '';
      throw AcquireException(_acquireMessage(e.response?.statusCode, reason));
    }
  }

  String _acquireMessage(int? code, String reason) {
    switch (code) {
      case 404:
        return 'Не нашлось ни в одном источнике';
      case 422:
        return reason.isNotEmpty ? reason : 'Нашлось только плохое качество';
      case 503:
        return 'Сервер сейчас не может качать (нет базы или связи с качалкой)';
      default:
        return reason.isNotEmpty ? reason : 'Сервер не ответил';
    }
  }

  /// Скачать файл трека в указанный путь.
  Future<void> downloadTrack(String id, String toPath) async {
    await _dio.download('/v1/music/$id/file', toPath);
  }

  /// Какие песни компьютер просит вернуть с телефона (разовый возврат стёртого
  /// с ПК, Alex TG 20261–20269, 21.09.2026): id, исполнитель, название, размер.
  /// Компьютер без этой ручки (старая версия программы) ответит 404 — бросит
  /// исключение, вызывающий код его глотает.
  Future<List<Map<String, dynamic>>> restoreWanted() async {
    final res = await _dio.get<List<dynamic>>('/api/restore/wanted');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Отдать компьютеру файл песни — он положит его на прежнее место. true —
  /// принят (или уже лежит там); false — компьютер файл не принял (не тот
  /// формат, обрезок, песни нет в списке): повторять бессмысленно. Нет связи
  /// или сбой на компьютере — бросит исключение, прогон остановится.
  Future<bool> restoreUpload(String id, File file) async {
    final len = await file.length();
    try {
      await _dio.put<dynamic>(
        '/api/restore/upload/$id',
        data: file.openRead(),
        options: Options(headers: {
          Headers.contentLengthHeader: len,
          Headers.contentTypeHeader: 'application/octet-stream',
        }),
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != null && code >= 400 && code < 500) return false;
      rethrow;
    }
  }

  /// Прислать компьютеру точный список песен на телефоне (id и размер файла) —
  /// для сверки телефона с компьютером в окне программы (Alex TG 20277–20279,
  /// 21.09.2026: «на телефоне столько песен, на компьютере столько»). Раньше
  /// компьютер знал состав только по журналу событий — приблизительно. Нет
  /// связи / старая программа на ПК — бросит исключение, вызывающий код
  /// его глотает.
  Future<void> sendInventory(String deviceId, List<({String id, int bytes})> items) async {
    await _dio.post<dynamic>('/api/phone/inventory', data: {
      'device_id': deviceId,
      'items': [
        for (final i in items) {'id': i.id, 'b': i.bytes},
      ],
    });
  }

  /// Сообщить компьютеру, каких из просимых песен на телефоне нет — ждать их
  /// файлы он перестаёт.
  Future<void> restoreMissing(List<String> ids) async {
    await _dio.post<dynamic>('/api/restore/missing', data: {'ids': ids});
  }

  /// Скачать обложку по прямой ссылке (Яндекс.Музыка) — чтобы играть офлайн
  /// вместе с песней, а не тянуть картинку по сети каждый раз.
  Future<void> downloadCover(String url, String toPath) => _dio.download(url, toPath);

  Future<Map<String, dynamic>> health() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/health');
    return res.data ?? {};
  }

  /// Отправить текст последнего падения приложения на сервер (чёрный ящик,
  /// Alex TG 19028). Попадёт в ленту «что делал сервер». Не критично —
  /// вызывающий глотает ошибку.
  Future<void> reportCrash(String deviceId, String text) async {
    await _dio.post<Map<String, dynamic>>('/v1/client-crash', data: {
      'device': deviceId,
      'text': text,
    });
  }

  /// Рельеф громкости трека (0..1 по каждому столбику) для полоски плеера.
  /// Нет данных / ошибка — null (полоска рисуется как раньше).
  Future<List<double>?> waveform(String id) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/waveform/$id');
      final bars = (res.data?['bars'] as List?)?.cast<num>();
      if (bars == null || bars.isEmpty) return null;
      return [for (final b in bars) (b.toDouble() / 255.0).clamp(0.0, 1.0)];
    } catch (_) {
      return null;
    }
  }

  /// Слепок вкуса — только версия (несколько байт), НЕ сами центры. Дёргаем
  /// после каждой синхронизации; если отличается от сохранённого локально —
  /// тянем полный [tasteCentroids]. Сервер недоступен → null (тихо, вкус
  /// не критичен для работы приложения).
  Future<String?> tasteCentroidsHash() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids-hash');
      return res.data?['hash'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Полный слепок вкуса (центры long_term+recent) — только когда хэш
  /// разошёлся с локальным (см. [tasteCentroidsHash]).
  Future<TasteCentroids?> tasteCentroids() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids');
      final data = res.data;
      if (data == null) return null;
      List<Uint8List> decode(String key) => [
            for (final s in (data[key] as List? ?? const []))
              base64Decode('$s'),
          ];
      return TasteCentroids(
        hash: '${data['hash'] ?? ''}',
        longTerm: decode('long_term'),
        recent: decode('recent'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Список залайканных на телефоне песен, которых сервер не узнаёт (Alex
  /// TG 15.09.2026: старая библиотека стёрта, а лайки на телефоне остались,
  /// хочет их видеть на компе и докачать). Сервер сам решает, чего не
  /// хватает в каталоге — тут просто отправка сырого списка. Сеть недоступна
  /// → тихо, не критично.
  Future<void> reportPhoneFavorites(List<Map<String, String>> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await _dio.post<void>('/api/phone/favorites', data: {'tracks': tracks});
    } catch (_) {}
  }

  /// Отпечатки треков — телефон дёргает сразу после скачивания и при
  /// разовом бэкфилле старых скачиваний. Отсутствующий id — тихо пропущен
  /// (не у каждого трека в каталоге есть отпечаток).
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final res = await _dio.post<Map<String, dynamic>>('/api/tracks/vectors', data: {'ids': ids});
      final vectors = (res.data?['vectors'] as Map?) ?? const {};
      return {
        for (final e in vectors.entries) '${e.key}': base64Decode('${e.value}'),
      };
    } catch (_) {
      return {};
    }
  }

  /// Отправить батч событий с телефона. Возвращает uuid принятых как новые
  /// (дубли сервер молча пропускает).
  Future<List<String>> postSyncEvents({
    required String deviceId,
    required List<Map<String, Object?>> events,
    int musicBytes = 0,
    String deviceName = 'Android',
    String transport = '',
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/sync/events', data: {
      'device': {
        'id': deviceId,
        'name': deviceName,
        'app_version': 'dev',
        'music_bytes': musicBytes,
        'transport': transport,
      },
      'events': events,
    });
    final acc = (res.data?['accepted'] as List?) ?? const [];
    return acc.map((e) => '$e').toList();
  }

  /// Сообщить серверу, сколько песен из пачки «Докачать ещё» уже скачано —
  /// чтобы в окне «Устройства» на компьютере было видно «качает: <песня>,
  /// N из M» (Alex TG 18928). Не критично: сервер не ответил — молча дальше.
  Future<void> syncProgress({
    required String deviceId,
    required int done,
    required int total,
    required String current,
    required bool active,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>('/v1/sync/progress', data: {
        'device_id': deviceId,
        'done': done,
        'total': total,
        'current': current,
        'active': active,
      });
    } catch (_) {
      // прогресс — необязательная мелочь, не мешаем скачиванию
    }
  }

  /// План ручной синхронизации, который Alex собрал в окне на компе (кнопка
  /// «Синхронизировать» → список с галочками → «Далее»). `add` — карточки
  /// треков к скачиванию, `remove` — id к удалению на телефоне. Плана нет
  /// (сервер ответил 204) — null.
  Future<
      ({
        List<Map<String, dynamic>> add,
        List<String> remove,
        String createdAt,
      })?> deviceSyncPlan(String deviceId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/device/plan',
      queryParameters: {'device': deviceId},
    );
    if (res.statusCode == 204 || res.data == null) return null;
    final add =
        ((res.data?['add'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final remove =
        ((res.data?['remove'] as List?) ?? const []).map((e) => '$e').toList();
    if (add.isEmpty && remove.isEmpty) return null;
    return (
      add: add,
      remove: remove,
      createdAt: '${res.data?['created_at'] ?? ''}',
    );
  }

  /// Отчитаться серверу, что план синхронизации выполнен — сервер его удалит.
  Future<void> ackSyncPlan(String deviceId) async {
    await _dio.post<Map<String, dynamic>>(
      '/v1/device/plan/ack',
      data: {'device': deviceId},
    );
  }

  /// Упорядочить очередь Потока по близости звучания к seed. Отдаём id всех
  /// скачанных треков, получаем их же в новом порядке (без seed).
  ///
  /// [reordered] = true только если подбор по звуку реально состоялся. Если у
  /// seed-песни нет «отпечатка» — вернётся тот же список в исходном порядке и
  /// `reordered: false`; телефон тогда не зажигает радио и пишет, что похожее
  /// не подобрать (06.09.2026).
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/stream/order', data: {
      'seed_id': seedId,
      'candidate_ids': candidateIds,
    });
    final list = (res.data?['track_ids'] as List?) ?? const [];
    return (
      ids: list.map((e) => '$e').toList(),
      reordered: res.data?['reordered'] == true,
    );
  }

  /// Состояние сервера для экрана «Сервер».
  Future<Map<String, dynamic>> adminStatus() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/status');
    return res.data ?? {};
  }

  Future<List<Map<String, dynamic>>> adminDevices() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/devices');
    return ((res.data?['devices'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> adminEvents({int limit = 20}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/events',
        queryParameters: {'limit': limit});
    return ((res.data?['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Список «больше не качать» (удалённое в плеере + старый чёрный список).
  Future<List<Map<String, dynamic>>> blocklist({int limit = 500}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/blocklist',
        queryParameters: {'limit': limit});
    return ((res.data?['blocked'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Убрать один ключ из списка «больше не качать» (случайно попал / передумал).
  Future<void> blocklistRemove(String key) async {
    await _dio.post<Map<String, dynamic>>('/v1/admin/blocklist/remove', data: {'key': key});
  }

  /// Лента «что делал сервер»: добавил трек, убрал, не нашёл, заменил на
  /// версию получше, ошибка. Новые сверху.
  Future<List<Map<String, dynamic>>> serverLog({int limit = 100}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/log',
        queryParameters: {'limit': limit});
    return ((res.data?['log'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }
}

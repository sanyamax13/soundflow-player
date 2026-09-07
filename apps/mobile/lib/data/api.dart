import 'package:dio/dio.dart';

import '../core/config.dart';

/// Заказ трека не удался — текст уже человеческий, можно показывать как есть.
class AcquireException implements Exception {
  AcquireException(this.message);
  final String message;
  @override
  String toString() => message;
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

  /// Скачать обложку по прямой ссылке (Яндекс.Музыка) — чтобы играть офлайн
  /// вместе с песней, а не тянуть картинку по сети каждый раз.
  Future<void> downloadCover(String url, String toPath) => _dio.download(url, toPath);

  Future<Map<String, dynamic>> health() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/health');
    return res.data ?? {};
  }

  /// Отправить батч событий с телефона. Возвращает uuid принятых как новые
  /// (дубли сервер молча пропускает).
  Future<List<String>> postSyncEvents({
    required String deviceId,
    required List<Map<String, Object?>> events,
    int musicBytes = 0,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/sync/events', data: {
      'device': {
        'id': deviceId,
        'name': 'Android',
        'app_version': 'dev',
        'music_bytes': musicBytes,
      },
      'events': events,
    });
    final acc = (res.data?['accepted'] as List?) ?? const [];
    return acc.map((e) => '$e').toList();
  }

  /// «Докачать ещё»: отдаём id уже скачанного, получаем следующую порцию
  /// каталога (избранное — вперёд), пока не наберётся budgetBytes.
  Future<({List<Map<String, dynamic>> tracks, int totalBytes})> nextLibraryBatch({
    required List<String> excludeIds,
    int budgetBytes = 20 * 1024 * 1024 * 1024,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/library/next-batch', data: {
      'exclude_ids': excludeIds,
      'budget_bytes': budgetBytes,
    });
    final list = ((res.data?['tracks'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final total = (res.data?['total_bytes'] as num?)?.toInt() ?? 0;
    return (tracks: list, totalBytes: total);
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

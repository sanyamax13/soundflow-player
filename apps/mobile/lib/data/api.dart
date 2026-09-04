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
  Api()
      : _dio = Dio(BaseOptions(
          baseUrl: apiBaseUrl,
          connectTimeout: const Duration(seconds: 8),
        ));

  final Dio _dio;

  /// Список треков с сервера.
  Future<List<Map<String, dynamic>>> tracks() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/tracks');
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

  /// Упорядочить очередь Потока по близости звучания к seed. Отдаём id всех
  /// скачанных треков, получаем их же в новом порядке (без seed). Сервер молчит
  /// или трек без «отпечатка» — вернётся то же, что дали, только без seed.
  Future<List<String>> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/stream/order', data: {
      'seed_id': seedId,
      'candidate_ids': candidateIds,
    });
    final list = (res.data?['track_ids'] as List?) ?? const [];
    return list.map((e) => '$e').toList();
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
}

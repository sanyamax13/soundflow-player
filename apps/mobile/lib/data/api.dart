import 'package:dio/dio.dart';

import '../core/config.dart';

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
}

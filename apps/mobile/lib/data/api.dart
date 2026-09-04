import 'package:dio/dio.dart';

import '../core/config.dart';
import 'auth_repo.dart';

/// Клиент к серверу с автоподстановкой пропуска в заголовок.
class Api {
  Api(this._auth) {
    _dio = Dio(BaseOptions(baseUrl: apiBaseUrl, connectTimeout: const Duration(seconds: 8)));
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (opts, handler) async {
      final t = await _auth.token();
      if (t != null) opts.headers['Authorization'] = 'Bearer $t';
      handler.next(opts);
    }));
  }

  final AuthRepo _auth;
  late final Dio _dio;

  /// Список тестовых треков с сервера.
  Future<List<Map<String, dynamic>>> tracks() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/tracks');
    final list = (res.data?['tracks'] as List?) ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Скачать файл трека в указанный путь. Возвращает размер в байтах.
  Future<int> downloadTrack(String id, String toPath) async {
    await _dio.download('/v1/music/$id/file', toPath);
    return 0; // размер читает вызывающий по файлу
  }

  Future<Map<String, dynamic>> health() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/health');
    return res.data ?? {};
  }
}

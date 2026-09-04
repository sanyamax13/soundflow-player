import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/config.dart';

/// Вход и хранение пропуска. Ключевое правило офлайн-первости:
/// на старте приложение НЕ ходит в сеть — только смотрит, есть ли
/// сохранённый пропуск. Есть — сразу внутрь.
class AuthRepo {
  AuthRepo({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: apiBaseUrl)),
        _store = storage ?? const FlutterSecureStorage();

  final Dio _dio;
  final FlutterSecureStorage _store;
  static const _tokenKey = 'sf_token';

  String? _cachedToken;

  /// Есть ли сохранённый пропуск — синхронной сети тут нет.
  Future<bool> hasToken() async {
    _cachedToken ??= await _store.read(key: _tokenKey);
    return _cachedToken != null && _cachedToken!.isNotEmpty;
  }

  Future<String?> token() async {
    _cachedToken ??= await _store.read(key: _tokenKey);
    return _cachedToken;
  }

  /// Вход по логину и паролю. Успех → пропуск сохранён.
  Future<void> login(String login, String password) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/login',
      data: {'login': login, 'password': password},
    );
    final token = res.data?['token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('сервер не вернул пропуск');
    }
    _cachedToken = token;
    await _store.write(key: _tokenKey, value: token);
  }

  Future<void> logout() async {
    _cachedToken = null;
    await _store.delete(key: _tokenKey);
  }
}

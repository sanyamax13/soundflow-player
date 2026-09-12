import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/update_check.dart';

void main() {
  test('находит более новую версию', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter('''
        {"version":"1.0.0","versionCode":40,
         "apkUrl":"https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+40.apk",
         "changelog":"тест","releasedAt":"2026-09-12T00:00:00+03:00"}
      ''');
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNotNull);
    expect(info!.versionCode, 40);
    expect(info.apkUrl, contains('SoundFlow-1.0.0+40.apk'));
  });

  test('своя версия не старше — обновления нет', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter('''
        {"version":"1.0.0","versionCode":35,
         "apkUrl":"https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+35.apk",
         "changelog":"","releasedAt":"2026-09-12T00:00:00+03:00"}
      ''');
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNull);
  });

  test('сервер недоступен — молча null, не бросает', () async {
    final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNull);
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);
  final String body;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    throw DioException(requestOptions: options, error: 'no network');
  }
}

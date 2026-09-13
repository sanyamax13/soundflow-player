import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/server_discovery.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);
  final Map<String, Map<String, dynamic>> responses; // url -> json body

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = responses[options.path];
    if (body == null) {
      return ResponseBody.fromString('not found', 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

void main() {
  test('находит первый адрес, который отвечает service:soundflow', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter({
        'http://192.168.1.63:8090/v1/health': {'status': 'alive', 'db': 'ok'},
        'http://192.168.1.104:8091/v1/health': {
          'status': 'alive',
          'db': 'ok',
          'service': 'soundflow',
        },
      });
    final found = await discoverServer(
      candidatesOverride: [
        'http://192.168.1.63:8090',
        'http://192.168.1.104:8091',
      ],
      dioOverride: dio,
    );
    expect(found, 'http://192.168.1.104:8091');
  });

  test('не путает чужой сервис на том же порту (нет поля service)', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter({
        'http://192.168.1.50:8090/v1/health': {'status': 'ok'},
      });
    final found = await discoverServer(
      candidatesOverride: ['http://192.168.1.50:8090'],
      dioOverride: dio,
    );
    expect(found, isNull);
  });

  test('никто не ответил — null', () async {
    final dio = Dio()..httpClientAdapter = _FakeAdapter({});
    final found = await discoverServer(
      candidatesOverride: ['http://192.168.1.1:8090', 'http://192.168.1.2:8091'],
      dioOverride: dio,
    );
    expect(found, isNull);
  });
}

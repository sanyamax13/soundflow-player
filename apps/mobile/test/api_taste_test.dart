import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/api.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);
  final Map<String, Map<String, dynamic>> responses; // path -> json body

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
  test('tasteCentroidsHash читает поле hash', () async {
    final api = Api(baseUrl: 'http://test');
    api.debugAdapter = _FakeAdapter({
      '/api/taste/centroids-hash': {'hash': 'abc123'},
    });
    expect(await api.tasteCentroidsHash(), 'abc123');
  });

  test('tasteCentroidsHash — сервер недоступен → null', () async {
    final api = Api(baseUrl: 'http://test');
    api.debugAdapter = _FakeAdapter({});
    expect(await api.tasteCentroidsHash(), isNull);
  });

  test('tasteCentroids декодирует base64 в векторы слоёв', () async {
    final api = Api(baseUrl: 'http://test');
    final vecBytes = base64Encode(Uint8List.fromList(List.filled(8, 1)));
    api.debugAdapter = _FakeAdapter({
      '/api/taste/centroids': {
        'hash': 'h1',
        'long_term': [vecBytes],
        'recent': <String>[],
      },
    });
    final res = await api.tasteCentroids();
    expect(res, isNotNull);
    expect(res!.hash, 'h1');
    expect(res.longTerm.length, 1);
    expect(res.recent, isEmpty);
  });

  test('trackVectors декодирует карту id->base64, пропускает отсутствующие', () async {
    final api = Api(baseUrl: 'http://test');
    final vecBytes = base64Encode(Uint8List.fromList(List.filled(8, 2)));
    api.debugAdapter = _FakeAdapter({
      '/api/tracks/vectors': {
        'vectors': {'t1': vecBytes},
      },
    });
    final res = await api.trackVectors(['t1', 't2']);
    expect(res.length, 1);
    expect(res['t1'], isNotNull);
    expect(res.containsKey('t2'), isFalse);
  });
}

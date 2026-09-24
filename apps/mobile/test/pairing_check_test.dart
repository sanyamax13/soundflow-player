import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/api.dart';

/// Api.pairingCheck/pairingConfirm — первое подключение с подтверждением
/// (Alex TG 24.09.2026). Настоящий локальный HTTP-сервер вместо мока — как в
/// restore_to_pc_test.dart.
void main() {
  test('pairingCheck: окно открыто — open:true и имя компьютера', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'open': true, 'name': 'sanyamax'}));
      await req.response.close();
    });

    final r = await Api.pairingCheck('http://127.0.0.1:${server.port}');
    expect(r, isNotNull);
    expect(r!.open, isTrue);
    expect(r.name, 'sanyamax');
  });

  test('pairingCheck: окно закрыто — open:false', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'open': false, 'name': 'sanyamax'}));
      await req.response.close();
    });

    final r = await Api.pairingCheck('http://127.0.0.1:${server.port}');
    expect(r, isNotNull);
    expect(r!.open, isFalse);
  });

  test('pairingCheck: старая программа без этой ручки (404) — null, не падает', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.statusCode = 404;
      await req.response.close();
    });

    final r = await Api.pairingCheck('http://127.0.0.1:${server.port}');
    expect(r, isNull);
  });

  test('pairingCheck: никто не ответил — null, не падает', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final port = server.port;
    await server.close(force: true); // порт свободен, но никто не слушает

    final r = await Api.pairingCheck('http://127.0.0.1:$port');
    expect(r, isNull);
  });

  test('pairingConfirm: компьютер подтвердил — true', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    String? method, path;
    server.listen((req) async {
      method = req.method;
      path = req.uri.path;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true, 'name': 'sanyamax'}));
      await req.response.close();
    });

    expect(await Api.pairingConfirm('http://127.0.0.1:${server.port}'), isTrue);
    expect((method, path), ('POST', '/api/pairing/confirm'));
  });

  test('pairingConfirm: окно уже закрылось (409) — false', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.statusCode = 409;
      req.response.write('окно подключения закрыто');
      await req.response.close();
    });

    expect(await Api.pairingConfirm('http://127.0.0.1:${server.port}'), isFalse);
  });
}

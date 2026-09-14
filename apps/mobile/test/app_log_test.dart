import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:soundflow/core/app_log.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

void main() {
  // Единственный тест намеренно последовательно проверяет запись, обрезку
  // по времени и очистку на ОДНОЙ временной папке — AppLog кэширует File
  // статически (как и CrashLog), так что несколько тестов с РАЗНЫМИ tmp-
  // папками в одном файле путали бы друг друга.
  test('пишет событие, обрезает записи старше 3 часов, читает и чистит', () async {
    final tmp = Directory.systemTemp.createTempSync('soundflow_app_log_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
    addTearDown(() => tmp.deleteSync(recursive: true));

    final logFile = File('${tmp.path}/app_log.txt');
    final old = DateTime.now().subtract(const Duration(hours: 4)).toIso8601String();
    await logFile.writeAsString('$old старое_событие elapsed_ms=999\n');

    await AppLog.event('radio_press', {'elapsed_ms': 42, 'candidates': 10});

    final text = await AppLog.read();
    expect(text, isNotNull);
    expect(text, isNot(contains('старое_событие')));
    expect(text, contains('radio_press'));
    expect(text, contains('elapsed_ms=42'));
    expect(text, contains('candidates=10'));

    await AppLog.clear();
    expect(await AppLog.read(), isNull);
  });
}

import 'dart:async';

import 'package:soundflow/core/local_taste.dart';

/// Для всех тестов: тяжёлый счёт (Поток, офлайн-радио) — синхронно. Настоящий
/// `Isolate.run` в `flutter test` не завершается (см. local_taste.dart offlineComputeRunner).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  offlineComputeRunner = <T>(body) async => body();
  await testMain();
}

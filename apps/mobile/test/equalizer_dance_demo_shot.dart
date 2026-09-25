// Демонстрация поведения «столбики впереди неподвижны, пройденные пляшут»
// (Alex TG 25.09.2026, вариант «А») — несколько кадров НАСТОЯЩЕГО виджета
// DotMatrixSeek с фиксированной позицией (30% песни) и реальным течением
// времени между кадрами (Stopwatch настоящий, не тестовые часы — ждём
// по-настоящему через tester.runAsync). Кадры потом склеиваются в mp4
// (см. scratchpad-скрипт), чтобы было видно движение, а не только форму.
// Запуск:
//   flutter test --update-goldens test/equalizer_dance_demo_shot.dart
// Картинки: test/goldens/dance_frame_0.png … dance_frame_5.png

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/features/player/dot_matrix_seek.dart';
import 'package:soundflow/features/player/player_controller.dart';

void main() {
  setUpAll(() async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
  });

  testWidgets('кадры: впереди — неподвижно, пройденное — пляшет', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 200));
    final controller = PlayerController();
    controller.duration.value = const Duration(seconds: 10);
    controller.position.value = const Duration(seconds: 3); // ~30% — граница неподвижное/пляшущее
    controller.playing.value = true; // заводит настоящий Stopwatch внутри виджета

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: DotMatrixSeek(controller: controller, tint: Afisha.lime),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));

    // 10 кадров по 250мс (было 6×220мс) — пик теперь падает 0.9с, старого
    // окна не хватало показать падение целиком (Alex TG 25.09.2026: «пусть
    // не так быстро прыгает»).
    for (var frame = 0; frame < 10; frame++) {
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dance_frame_$frame.png'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await t.pump(const Duration(milliseconds: 16));
    }
  });
}

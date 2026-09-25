// Рендер НАСТОЯЩЕГО виджета DotMatrixSeek после скругления столбиков
// («полосу прогресса оставь как есть, дизайн чуть переделай под iOS/Samsung»,
// Alex TG 25.09.2026) — не макет, реальный _EqualizerPainter из
// dot_matrix_seek.dart. PlayerController создаётся по-настоящему;
// AudioSession падает и ловится внутри (try/catch в _initSession) — это
// штатно для виджет-теста, как и написано в комментарии там же. Запуск:
//   flutter test --update-goldens test/equalizer_pill_shot.dart
// Картинка: test/goldens/equalizer_pill.png

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

  testWidgets('полоса прогресса — скруглённые столбики эквалайзера', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 200));
    final controller = PlayerController();
    controller.duration.value = const Duration(minutes: 3, seconds: 41);
    controller.position.value = const Duration(minutes: 1, seconds: 22);

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: DotMatrixSeek(
            controller: controller,
            tint: Afisha.lime,
          ),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/equalizer_pill.png'));
  });
}

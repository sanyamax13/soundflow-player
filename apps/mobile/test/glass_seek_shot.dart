// Рендер НАСТОЯЩЕГО виджета DotMatrixSeek после скругления столбиков
// («полосу прогресса оставь как есть, дизайн чуть переделай под iOS/Samsung»,
// Alex TG 25.09.2026) — не макет, реальный _EqualizerPainter из
// dot_matrix_seek.dart. PlayerController создаётся по-настоящему;
// AudioSession падает и ловится внутри (try/catch в _initSession) — это
// штатно для виджет-теста, как и написано в комментарии там же. Запуск:
//   flutter test --update-goldens test/glass_seek_shot.dart
// Картинка: test/goldens/glass_seek.png

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/features/player/dot_matrix_seek.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/features/player/seek_skin.dart';

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
    final grotesk = File('assets/fonts/SpaceGrotesk-Regular.ttf');
    if (grotesk.existsSync()) {
      await (FontLoader('SpaceGrotesk')
            ..addFont(Future.value(ByteData.view(grotesk.readAsBytesSync().buffer))))
          .load();
    }
  });

  testWidgets('полоса прогресса — вид «Стекло»', (t) async {
    seekSkin.value = SeekSkin.glass;
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
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/glass_seek.png'));
  });
}

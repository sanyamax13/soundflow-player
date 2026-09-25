// Рендер НАСТОЯЩЕГО экрана «Настройки» после того, как AppleSection/AppleRow
// заматированы (Alex TG 25.09.2026: «переделаем всё приложение в таком
// стиле») — показывает, как новый стиль ложится на уже существующий экран,
// без макета/мокапа. Не проверка логики. Запуск:
//   flutter test --update-goldens test/settings_glass_shot.dart
// Картинка: test/goldens/settings_glass.png

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/features/settings/settings_screen.dart';

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

  testWidgets('экран «Настройки» с новым матовым AppleSection', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: const SettingsScreen(),
    ));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_glass.png'));
  });
}

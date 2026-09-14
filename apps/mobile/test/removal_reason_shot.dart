// Рендер листа причин «Убрать совсем» в PNG — для показа Alex. Не проверка
// логики. Запуск:
//   flutter test --update-goldens test/removal_reason_shot.dart
// Картинка: test/goldens/removal_reason_sheet.png

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/removal_reasons.dart';
import 'package:soundflow/core/theme.dart';

Widget _app() => Builder(
      builder: (context) => Scaffold(
        backgroundColor: Afisha.bg,
        body: Center(
          child: FilledButton(
            onPressed: () => pickRemovalReason(context),
            child: const Text('открыть'),
          ),
        ),
      ),
    );

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

  testWidgets('лист причин «Убрать совсем» — четыре пункта, не пять', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: _app(),
    ));
    await t.tap(find.text('открыть'));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/removal_reason_sheet.png'));
  });
}

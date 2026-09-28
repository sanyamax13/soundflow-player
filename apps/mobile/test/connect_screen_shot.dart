// Картинка экрана «Подключите компьютер» для инструкции второму человеку (28.09.2026).
//   flutter test --update-goldens test/connect_screen_shot.dart  → test/goldens/connect_screen.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/features/onboarding/connect_screen.dart';

void main() {
  setUpAll(() async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      await (FontLoader('Inter')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
    }
    final icons = File('/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)))).load();
    }
  });

  testWidgets('экран первого запуска', (t) async {
    await t.binding.setSurfaceSize(const Size(412, 892));
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: Afisha.theme(), home: const ConnectScreen()),
    ));
    await t.pump();
    await expectLater(find.byType(ConnectScreen), matchesGoldenFile('goldens/connect_screen.png'));
  });
}

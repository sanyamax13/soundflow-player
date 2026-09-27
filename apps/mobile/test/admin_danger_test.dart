// «Полный сброс» на экране «Связь с домом» — красной надписью внизу, с подтверждением.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/admin/admin_screen.dart';

class _FakeApi extends Api {
  @override
  Future<Map<String, dynamic>> adminStatus() async => {'db': 'ok'};
}

Future<Widget> _app() async {
  final api = _FakeApi();
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  final sync = SyncRepo(api, db);
  final downloads = DownloadsRepo(api, db, sync);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(downloads),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(downloads)),
    ],
    child: MaterialApp(theme: Afisha.theme(), home: const AdminScreen()),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  // 26.09.2026 (разбор Gemini, Alex «да»): «Показать опасное» убрано — «Полный сброс»
  // красной надписью в самом низу «Связи с домом»; от случайного нажатия защищает вопрос.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('«Полный сброс» внизу, без «Показать опасное»', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(await _app());
    await pumpFrames(tester);

    expect(find.text('Показать опасное'), findsNothing);
    expect(find.text('Полный сброс'), findsOneWidget);
    expect(find.text('На связи'), findsOneWidget);
  });

  testWidgets('нажатие «Полный сброс» по-прежнему спрашивает подтверждение', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(await _app());
    await pumpFrames(tester);
    await tester.tap(find.text('Полный сброс'));
    await pumpFrames(tester);

    expect(find.text('Полный сброс?'), findsOneWidget);
    expect(find.text('Стереть всё'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await pumpFrames(tester);
    expect(find.text('Полный сброс?'), findsNothing);
  });
}

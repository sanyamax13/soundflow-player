// «Полный сброс» на экране «Сервер» спрятан за «Показать опасное» (ревизия 20.09.2026, пункт «убрать вглубь»):
// раньше кнопка лежала на виду, в двух тапах от «стереть всю музыку и лайки на телефоне».

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
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
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      syncProvider.overrideWithValue(sync),
    ],
    child: MaterialApp(theme: Afisha.theme(), home: const AdminScreen()),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('«Полный сброс» не виден, пока не нажато «Показать опасное»', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    expect(find.text('Полный сброс'), findsNothing, reason: 'кнопка стирания всего не должна лежать на виду');
    expect(find.text('Показать опасное'), findsOneWidget);
    expect(find.text('Компьютер на связи'), findsOneWidget, reason: 'связь и синхронизация остались на виду');

    await tester.tap(find.text('Показать опасное'));
    await tester.pumpAndSettle();
    expect(find.text('Полный сброс'), findsOneWidget);
    expect(find.textContaining('Отменить нельзя'), findsOneWidget);
  });

  testWidgets('нажатие «Полный сброс» по-прежнему спрашивает подтверждение', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Показать опасное'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Полный сброс'));
    await tester.pumpAndSettle();

    expect(find.text('Полный сброс?'), findsOneWidget);
    expect(find.text('Стереть всё'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Полный сброс?'), findsNothing);
  });
}

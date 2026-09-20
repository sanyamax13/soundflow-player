import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/config.dart';
import 'package:soundflow/core/notice.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/features/profile/server_url_screen.dart';

/// Опус-ревью телефона 14.09.2026, пункт 5: «Вернуть обычный адрес» раньше
/// молча подставлял хардкод 127.0.0.1:8090 вместо реально рабочего Wi-Fi
/// адреса, а найденный автосканом адрес терялся без отдельного «Сохранить».

Future<Widget> _app(Db db, Api api) async => ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        dbProvider.overrideWithValue(db),
      ],
      child: MaterialApp(
        theme: Afisha.theme(),
        builder: (context, child) => NoticeHost(child: child ?? const SizedBox.shrink()),
        home: const ServerUrlScreen(),
      ),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  test('kDefaultApiBase не изменился (иначе тест ниже теряет смысл)', () {
    expect(kDefaultApiBase, 'http://127.0.0.1:8090');
  });

  testWidgets('«Сохранить» запоминает адрес и как «последний рабочий»', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final api = Api(baseUrl: kDefaultApiBase);
    await tester.pumpWidget(await _app(db, api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '192.168.1.50:8091');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(await db.kvGet('server_url'), 'http://192.168.1.50:8091');
    expect(await db.kvGet('last_reachable_server_url'), 'http://192.168.1.50:8091');
    await db.close();
  });

  testWidgets('«Вернуть последний рабочий адрес» — подставляет запомненный, не хардкод USB',
      (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.kvSet('last_reachable_server_url', 'http://192.168.1.104:8091');
    final api = Api(baseUrl: kDefaultApiBase);
    await tester.pumpWidget(await _app(db, api));
    await tester.pumpAndSettle();

    // Меняем поле на что-то другое, потом жмём кнопку — должно вернуться
    // именно к запомненному рабочему, а не к 127.0.0.1:8090.
    await tester.enterText(find.byType(TextField), 'что-то сломанное');
    await tester.tap(find.text('Вернуть последний рабочий адрес'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'http://192.168.1.104:8091');
    await db.close();
  });

  testWidgets('ни разу не было рабочего адреса — откатывает на обычный USB, с объяснением',
      (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final api = Api(baseUrl: kDefaultApiBase);
    await tester.pumpWidget(await _app(db, api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Вернуть последний рабочий адрес'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, kDefaultApiBase);
    expect(find.textContaining('ещё не запоминали'), findsOneWidget);
    await db.close();
  });
}

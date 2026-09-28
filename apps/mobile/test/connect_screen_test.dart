import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/onboarding/connect_screen.dart';

void main() {
  testWidgets('первый запуск: одна большая кнопка «Найти компьютер» и «Позже»', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ConnectScreen())));
    expect(find.text('Подключите компьютер'), findsOneWidget);
    final find1 = tester.getSize(find.byKey(const ValueKey('connect_find')));
    expect(find1.height, greaterThanOrEqualTo(64));
    expect(find.byKey(const ValueKey('connect_later')), findsOneWidget);
    // кнопки — в нижней половине экрана
    final screenH = tester.getSize(find.byType(Scaffold)).height;
    expect(tester.getTopLeft(find.byKey(const ValueKey('connect_find'))).dy, greaterThan(screenH / 2));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/profile/profile_screen.dart';

void main() {
  testWidgets('строка "О программе" видна всегда', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
    await tester.pumpAndSettle();
    expect(find.text('О программе'), findsOneWidget);
  });
}

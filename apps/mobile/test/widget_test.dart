import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/main.dart';

void main() {
  testWidgets('каркас показывает пять вкладок', (tester) async {
    await tester.pumpWidget(const SoundFlowApp());

    for (final label in ['Поток', 'Чарты', 'Библиотека', 'Профиль', 'Настройки']) {
      expect(find.text(label), findsWidgets, reason: 'нет вкладки $label');
    }
  });

  testWidgets('переключение вкладки меняет заголовок', (tester) async {
    await tester.pumpWidget(const SoundFlowApp());
    expect(find.text('Поток — скоро'), findsOneWidget);

    await tester.tap(find.text('Чарты'));
    await tester.pumpAndSettle();
    expect(find.text('Чарты — скоро'), findsOneWidget);
  });
}

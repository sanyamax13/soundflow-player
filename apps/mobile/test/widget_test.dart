import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/auth_repo.dart';
import 'package:soundflow/main.dart';

class _FakeAuth extends AuthRepo {
  _FakeAuth({required this.signedIn});
  bool signedIn;
  @override
  Future<bool> hasToken() async => signedIn;
  @override
  Future<String?> token() async => signedIn ? 'fake' : null;
  @override
  Future<void> login(String login, String password) async => signedIn = true;
}

class _FakeApi extends Api {
  _FakeApi(super.auth);
  @override
  Future<List<Map<String, dynamic>>> tracks() async => const [];
  @override
  Future<Map<String, dynamic>> health() async => const {'status': 'alive'};
}

Widget _app(AuthRepo auth) => SoundFlowApp(authRepo: auth, api: _FakeApi(auth));

void main() {
  testWidgets('нет пропуска → экран входа', (tester) async {
    await tester.pumpWidget(_app(_FakeAuth(signedIn: false)));
    await tester.pumpAndSettle();

    expect(find.text('Войти'), findsOneWidget);
    expect(find.text('Поток'), findsNothing);
  });

  testWidgets('есть пропуск → сразу пять вкладок, без экрана входа', (tester) async {
    await tester.pumpWidget(_app(_FakeAuth(signedIn: true)));
    await tester.pumpAndSettle();

    expect(find.text('Войти'), findsNothing);
    for (final label in ['Поток', 'Чарты', 'Библиотека', 'Профиль', 'Настройки']) {
      expect(find.text(label), findsWidgets, reason: 'нет вкладки $label');
    }
  });

  testWidgets('вкладка Библиотека открывается без ошибки связи', (tester) async {
    await tester.pumpWidget(_app(_FakeAuth(signedIn: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Библиотека'));
    await tester.pumpAndSettle();

    expect(find.text('Сервер не ответил. Запущен ли он?'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Библиотека'), findsOneWidget);
  });
}

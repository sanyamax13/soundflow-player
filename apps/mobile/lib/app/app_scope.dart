import 'package:flutter/widgets.dart';

import '../data/api.dart';
import '../data/auth_repo.dart';

/// Общие сервисы, доступные из дерева виджетов. На каркасе — вместо
/// Riverpod (§5 плана); в тестах сюда подставляются подделки.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.authRepo,
    required this.api,
    required super.child,
  });

  final AuthRepo authRepo;
  final Api api;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден выше по дереву');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      authRepo != oldWidget.authRepo || api != oldWidget.api;
}

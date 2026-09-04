import 'package:flutter/widgets.dart';

import '../data/api.dart';
import '../data/downloads_repo.dart';
import '../features/player/player_controller.dart';

/// Общие сервисы, доступные из дерева виджетов. На каркасе — вместо
/// Riverpod (§5 плана); в тестах сюда подставляются подделки.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.downloads,
    required this.player,
    required super.child,
  });

  final Api api;
  final DownloadsRepo downloads;
  final PlayerController player;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден выше по дереву');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      api != oldWidget.api || downloads != oldWidget.downloads || player != oldWidget.player;
}

import 'package:flutter/material.dart';

import '../features/my_music/my_music_screen.dart';
import '../features/placeholder_screen.dart';
import '../features/player/mini_player.dart';
import '../features/profile/profile_screen.dart';
import 'app_scope.dart';

/// Каркас приложения. Вкладки (решение Alex 04.09.2026): Поток · Моя музыка ·
/// Профиль. Настройки — внутри профиля. Чарты и альбомы убраны.
/// Мини-плеер над вкладками.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  static const _labels = ['Поток', 'Моя музыка', 'Профиль'];
  static const _icons = [Icons.graphic_eq, Icons.library_music_outlined, Icons.person_outline];

  // Экран строим только когда вкладку открыли — не дёргаем сеть на старте.
  Widget _screen(int i) => switch (i) {
        1 => const MyMusicScreen(),
        2 => const ProfileScreen(),
        _ => const PlaceholderScreen(title: 'Поток', icon: Icons.graphic_eq),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screen(_tab),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayer(controller: AppScope.of(context).player),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (var i = 0; i < _labels.length; i++)
                NavigationDestination(icon: Icon(_icons[i]), label: _labels[i]),
            ],
          ),
        ],
      ),
    );
  }
}

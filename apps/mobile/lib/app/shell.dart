import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../features/my_music/my_music_screen.dart';
import '../features/player/mini_player.dart';
import '../features/profile/profile_screen.dart';
import '../features/stream/stream_screen.dart';
import 'app_scope.dart';

/// Каркас приложения. Вкладки (решение Alex 04.09.2026): Поток · Моя музыка ·
/// Профиль. Настройки — внутри профиля. Чарты и альбомы убраны.
/// Мини-плеер над вкладками — кроме «Потока», там и так плеер на весь экран.
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
        _ => StreamScreen(onOpenLibrary: () => setState(() => _tab = 1)),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screen(_tab),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // На «Потоке» и так на весь экран управление плеером — полоска
          // здесь была бы тем же самым второй раз (05.09.2026).
          if (_tab != 0) MiniPlayer(controller: AppScope.of(context).player),
          // Плавный переход от полноэкранного плеера к нижнему меню — мягкая
          // полоса-градиент вместо резкого стыка чёрного низа плеера и
          // панели #0F0F0F (Alex 06.09.2026).
          if (_tab == 0)
            Container(
              height: 36,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Afisha.surface],
                ),
              ),
            ),
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

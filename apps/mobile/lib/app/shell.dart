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
    // На «Потоке» плеер занимает весь экран — пускаем его и под меню, а само
    // меню делаем прозрачным: низ сам «подстраивается под обложку», без
    // серой полосы и стыка (Alex 06.09.2026). На других вкладках меню
    // обычное, на чёрном фоне.
    final onStream = _tab == 0;
    return Scaffold(
      extendBody: onStream,
      body: _screen(_tab),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tab != 0) MiniPlayer(controller: AppScope.of(context).player),
          NavigationBar(
            backgroundColor: onStream ? Colors.transparent : Afisha.surface,
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

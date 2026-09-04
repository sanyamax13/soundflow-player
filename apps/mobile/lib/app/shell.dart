import 'package:flutter/material.dart';

import '../features/library/library_screen.dart';
import '../features/placeholder_screen.dart';

/// Каркас приложения: пять вкладок из плана
/// (Поток · Чарты · Библиотека · Профиль · Настройки).
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  static const _tabs = <_Tab>[
    _Tab('Поток', Icons.graphic_eq),
    _Tab('Чарты', Icons.leaderboard_outlined),
    _Tab('Библиотека', Icons.library_music_outlined),
    _Tab('Профиль', Icons.person_outline),
    _Tab('Настройки', Icons.settings_outlined),
  ];

  Widget _screen(int i) {
    if (i == 2) return const LibraryScreen();
    return PlaceholderScreen(title: _tabs[i].label, icon: _tabs[i].icon);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [for (var i = 0; i < _tabs.length; i++) _screen(i)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }
}

class _Tab {
  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

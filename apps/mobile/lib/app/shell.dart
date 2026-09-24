import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../features/my_music/my_music_screen.dart';
import '../features/player/mini_player.dart';
import '../features/profile/profile_screen.dart';
import '../features/stream/stream_screen.dart';
import 'providers.dart';

/// Каркас приложения. Вкладки (решение Alex 04.09.2026): Поток · Моя музыка ·
/// Профиль. Настройки — внутри профиля. Чарты и альбомы убраны.
/// Мини-плеер над вкладками — кроме «Потока», там и так плеер на весь экран.
/// Нижнее меню — как в iPhone (Alex TG 20345, 21.09.2026): значки Cupertino,
/// подпись 10 pt, выбранная вкладка — лаймовая и «заливкой».
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  int _tab = 0;

  // Построенные экраны храним тут и показываем через IndexedStack — вкладка,
  // на которую уже заходили, не пересоздаётся заново при возврате (не крутит
  // спиннер повторно, Alex TG 24.09.2026). Слот остаётся null, пока на
  // вкладку ни разу не зашли — сеть/база на старте всё так же не трогаем.
  final List<Widget?> _built = List<Widget?>.filled(3, null);

  static const _labels = ['Поток', 'Моя музыка', 'Профиль'];
  static const _icons = [
    CupertinoIcons.dot_radiowaves_left_right,
    CupertinoIcons.music_albums,
    CupertinoIcons.person_crop_circle,
  ];
  static const _iconsOn = [
    CupertinoIcons.dot_radiowaves_left_right,
    CupertinoIcons.music_albums_fill,
    CupertinoIcons.person_crop_circle_fill,
  ];

  // Экран строим только когда вкладку открыли — не дёргаем сеть на старте.
  Widget _screen(int i) => switch (i) {
        1 => const MyMusicScreen(),
        2 => const ProfileScreen(),
        _ => const StreamScreen(),
      };

  void _select(int i) {
    if (i == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    // На «Потоке» плеер занимает весь экран — пускаем его и под меню, а само
    // меню делаем прозрачным: низ сам «подстраивается под обложку», без
    // серой полосы и стыка (Alex 06.09.2026). На других вкладках меню
    // обычное, на чёрном фоне.
    final onStream = _tab == 0;
    _built[_tab] ??= _screen(_tab);
    return Scaffold(
      extendBody: onStream,
      body: IndexedStack(
        index: _tab,
        children: [
          for (var i = 0; i < _built.length; i++) _built[i] ?? const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tab != 0) MiniPlayer(controller: ref.read(playerProvider)),
          _AppleTabBar(
            selected: _tab,
            transparent: onStream,
            onSelect: _select,
            labels: _labels,
            icons: _icons,
            iconsOn: _iconsOn,
          ),
        ],
      ),
    );
  }
}

/// Нижнее меню в стиле iOS: тонкая линия сверху, значок 26 pt и подпись 10 pt.
/// Свою «стеклянность» не рисуем: под меню нет прокручиваемого содержимого,
/// размывать нечего.
class _AppleTabBar extends StatelessWidget {
  const _AppleTabBar({
    required this.selected,
    required this.transparent,
    required this.onSelect,
    required this.labels,
    required this.icons,
    required this.iconsOn,
  });

  final int selected;
  final bool transparent;
  final ValueChanged<int> onSelect;
  final List<String> labels;
  final List<IconData> icons;
  final List<IconData> iconsOn;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: transparent ? Colors.transparent : const Color(0xFF121214),
        border: Border(
          top: BorderSide(
            color: transparent ? Colors.transparent : const Color(0xFF2A2A2D),
            width: 0.5,
          ),
        ),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: _TabItem(
                  label: labels[i],
                  icon: i == selected ? iconsOn[i] : icons[i],
                  on: i == selected,
                  onTap: () => onSelect(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.label,
    required this.icon,
    required this.on,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = on ? Afisha.lime : Afisha.gray;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

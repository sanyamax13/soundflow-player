import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'player_view.dart';

/// Полноэкранный плеер, открытый поверх текущего экрана (тап по мини-плееру).
/// Само тело — общее с вкладкой «Поток», см. player_view.dart.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: PlayerView(onDismiss: () => Navigator.pop(context)),
    );
  }
}

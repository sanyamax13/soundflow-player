import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import 'player_controller.dart';

/// Тело полноэкранного плеера: обложка на весь экран фоном (вариант «C» из
/// показанных Alex 5 макетов, 04.09.2026 — выбрал этот), поверх нижней части —
/// градиент и управление (перемотка, назад/вперёд, пауза, перемешивание,
/// сердечко). Общий виджет для двух мест (05.09.2026, Alex попросил убрать
/// список из «Потока» и оставить только это как стартовый экран вкладки):
/// - вкладка «Поток» вставляет его прямо в тело, без кнопки закрытия;
/// - [NowPlayingScreen] открывает его поверх текущего экрана (тап по
///   мини-плееру), с кнопкой «вниз».
class PlayerView extends StatefulWidget {
  const PlayerView({super.key, this.onDismiss, this.emptyState});

  /// Кнопка «вниз» в углу. Есть, когда экран открыт поверх другого (пуш) —
  /// во вкладке «Поток» сворачивать некуда, там её нет.
  final VoidCallback? onDismiss;

  /// Чем показывать состояние "ещё ничего не играет" вместо надписи по
  /// умолчанию. Нужно «Потоку» (05.09.2026, Alex: не начинать играть само
  /// при открытии вкладки) — там вместо текста кнопка «начать».
  final Widget? emptyState;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  bool _wired = false;
  String? _favTrackId;
  bool _fav = false;
  // Ссылку на контроллер держим в поле, а не берём через AppScope.of(context)
  // по требованию — в dispose() контекст уже недействителен (баг вылез,
  // когда этот экран впервые стал не только пуш-маршрутом, а телом вкладки
  // «Поток», которое реально размонтируется при переключении вкладок/тестах).
  PlayerController? _controller;

  PlayerController get _p => _controller!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wired) {
      _wired = true;
      _controller = AppScope.of(context).player;
      _p.now.addListener(_onNowChanged);
      _onNowChanged();
    }
  }

  @override
  void dispose() {
    _controller?.now.removeListener(_onNowChanged);
    super.dispose();
  }

  void _onNowChanged() => _syncFav();

  Future<void> _syncFav() async {
    final cur = _p.now.value;
    if (cur == null || cur.id == _favTrackId) return;
    final v = await AppScope.of(context).downloads.favorite(cur.id);
    if (!mounted) return;
    setState(() {
      _favTrackId = cur.id;
      _fav = v;
    });
  }

  Future<void> _toggleFav() async {
    final cur = _p.now.value;
    if (cur == null) return;
    final v = !_fav;
    setState(() => _fav = v);
    await AppScope.of(context).downloads.setFavorite(cur.id, v);
  }

  String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: _p.now,
      builder: (context, now, _) {
        if (now == null) {
          return widget.emptyState ??
              const Center(
                child: Text('Ничего не играет', style: TextStyle(color: Afisha.inkDim)),
              );
        }
        final coverPath = now.coverPath;
        final hasCover = coverPath != null && File(coverPath).existsSync();
        return Stack(
          key: ValueKey(now.id),
          fit: StackFit.expand,
          children: [
            // Обложка на весь экран — фон. Нет обложки — тёмная заглушка
            // с той же нотой, что и везде в списках.
            hasCover
                ? Image.file(File(coverPath), fit: BoxFit.cover)
                : Container(
                    color: Afisha.surfaceHi,
                    child: const Center(
                      child: Icon(Icons.graphic_eq, color: Afisha.lime, size: 96),
                    ),
                  ),
            // Градиент снизу — чтобы текст и кнопки читались на любой обложке.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0.35, 1.0],
                ),
              ),
            ),
            // Лёгкое затемнение сверху — чтобы кнопка "вниз" была видна и на
            // светлой обложке.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black45, Colors.transparent],
                  stops: [0.0, 0.18],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  if (widget.onDismiss != null)
                    Align(
                      alignment: Alignment.topLeft,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                        onPressed: widget.onDismiss,
                      ),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Column(
                      children: [
                        Text(now.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 22, color: Colors.white, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Text(now.artist, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 20),
                        _ProgressBar(controller: _p, label: _mmss),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: _p.shuffle,
                              builder: (_, sh, _) => IconButton(
                                icon: Icon(Icons.shuffle,
                                    color: sh ? Afisha.lime : Colors.white70),
                                onPressed: _p.toggleShuffle,
                              ),
                            ),
                            IconButton(
                              iconSize: 40,
                              color: Colors.white,
                              icon: const Icon(Icons.skip_previous),
                              onPressed: _p.prev,
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: _p.playing,
                              builder: (_, pl, _) => IconButton(
                                iconSize: 64,
                                color: Afisha.lime,
                                icon: Icon(pl ? Icons.pause_circle_filled : Icons.play_circle_filled),
                                onPressed: _p.toggle,
                              ),
                            ),
                            IconButton(
                              iconSize: 40,
                              color: Colors.white,
                              icon: const Icon(Icons.skip_next),
                              onPressed: _p.next,
                            ),
                            IconButton(
                              icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                                  color: _fav ? Afisha.lime : Colors.white70),
                              onPressed: _toggleFav,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.controller, required this.label});
  final PlayerController controller;
  final String Function(Duration) label;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.duration,
      builder: (context, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: controller.position,
        builder: (context, pos, _) {
          final total = dur.inMilliseconds;
          final value = total <= 0 ? 0.0 : pos.inMilliseconds.clamp(0, total).toDouble();
          return Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  max: total <= 0 ? 1 : total.toDouble(),
                  activeColor: Afisha.lime,
                  inactiveColor: Colors.white24,
                  onChanged:
                      total <= 0 ? null : (v) => controller.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label(pos), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Text(label(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

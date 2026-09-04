import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import 'player_controller.dart';

/// Полноэкранный плеер: обложка-заглушка, перемотка, назад/вперёд, пауза,
/// перемешивание, сердечко. Открывается тапом по нижней плашке или из «Потока».
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  bool _wired = false;
  String? _favTrackId;
  bool _fav = false;

  PlayerController get _p => AppScope.of(context).player;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wired) {
      _wired = true;
      _p.now.addListener(_onNowChanged);
      _onNowChanged();
    }
  }

  @override
  void dispose() {
    _p.now.removeListener(_onNowChanged);
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Играет сейчас'),
      ),
      body: ValueListenableBuilder<NowPlaying?>(
        valueListenable: _p.now,
        builder: (context, now, _) {
          if (now == null) {
            return const Center(
              child: Text('Ничего не играет', style: TextStyle(color: Afisha.inkDim)),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                const Spacer(),
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Afisha.surfaceHi,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.graphic_eq, color: Afisha.lime, size: 96),
                  ),
                ),
                const SizedBox(height: 28),
                Text(now.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22, color: Afisha.ink, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(now.artist, style: const TextStyle(color: Afisha.inkDim)),
                const SizedBox(height: 24),
                _ProgressBar(controller: _p, label: _mmss),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: _p.shuffle,
                      builder: (_, sh, _) => IconButton(
                        icon: Icon(Icons.shuffle, color: sh ? Afisha.lime : Afisha.inkDim),
                        onPressed: _p.toggleShuffle,
                      ),
                    ),
                    IconButton(
                      iconSize: 40,
                      color: Afisha.ink,
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
                      color: Afisha.ink,
                      icon: const Icon(Icons.skip_next),
                      onPressed: _p.next,
                    ),
                    IconButton(
                      icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                          color: _fav ? Afisha.lime : Afisha.inkDim),
                      onPressed: _toggleFav,
                    ),
                  ],
                ),
                const Spacer(),
              ],
            ),
          );
        },
      ),
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
                  inactiveColor: Afisha.line,
                  onChanged:
                      total <= 0 ? null : (v) => controller.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label(pos), style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
                    Text(label(dur), style: const TextStyle(color: Afisha.inkDim, fontSize: 12)),
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

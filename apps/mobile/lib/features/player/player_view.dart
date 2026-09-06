import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/cover_thumb.dart';
import '../../core/theme.dart';
import 'cover_backdrop.dart';
import 'cover_palette.dart';
import 'player_controller.dart';

/// Полноэкранный плеер — вариант 4.2 «Радио-объект» (Alex TG 18568–18590,
/// с разбором внешнего дизайнера). Управление в первую очередь жестами по
/// обложке, снизу — маленький ряд кнопок как подсказка/подстраховка.
///
/// Жесты по обложке:
///  • тап — пауза/играть;
///  • двойной тап — «нравится» (сердце всплывает);
///  • смахнуть влево/вправо — следующая/предыдущая (обложка едет за пальцем);
///  • смахнуть вверх — очередь «Дальше»;
///  • смахнуть вниз — свернуть плеер (если открыт поверх);
///  • долгое нажатие — меню действий (радио, не хочу эту версию, скрыть
///    исполнителя, больше/меньше такого, почему это играет).
/// Волна внизу — перемотка (вести пальцем), зона касания на всю высоту.
/// «?» вверху — та же инструкция внутри приложения; в первый раз
/// показывается сама.
///
/// Общий виджет для двух мест:
///  • вкладка «Поток» вставляет его в тело, без кнопки «вниз»;
///  • [NowPlayingScreen] открывает поверх (тап по мини-плееру), с «вниз».
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key, this.onDismiss, this.emptyState});

  final VoidCallback? onDismiss;
  final Widget? emptyState;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView>
    with TickerProviderStateMixin {
  bool _wired = false;
  PlayerController? _controller;
  PlayerController get _p => _controller!;

  String? _favTrackId;
  bool _fav = false;

  final ValueNotifier<Color> _tint = ValueNotifier(Afisha.surfaceHi);

  late final AnimationController _bg;
  late final AnimationController _heart;
  late final AnimationController _dragX;
  late final AnimationController _menu;
  late final AnimationController _breathe;

  bool _menuOpen = false;
  bool _showHelp = false;

  String? _toastText;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _bg = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _heart = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _dragX = AnimationController.unbounded(vsync: this, value: 0);
    _menu = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 180),
    );
    // «Дыхание» обложки — медленный пульс масштаба, пока играет музыка.
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    );
  }

  void _onPlaying() {
    if (_p.playing.value) {
      if (!_breathe.isAnimating) _breathe.repeat(reverse: true);
    } else {
      _breathe.stop();
      _breathe.animateTo(0,
          duration: const Duration(milliseconds: 500), curve: Curves.easeOut);
    }
  }

  void _openMenu() {
    setState(() => _menuOpen = true);
    _menu.forward(from: 0);
  }

  Future<void> _closeMenu() async {
    await _menu.reverse();
    if (mounted) setState(() => _menuOpen = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wired) {
      _wired = true;
      _controller = ref.read(playerProvider);
      _p.now.addListener(_onNow);
      _p.playing.addListener(_onPlaying);
      _onNow();
      _onPlaying();
      _maybeShowHelpFirstRun();
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _controller?.now.removeListener(_onNow);
    _controller?.playing.removeListener(_onPlaying);
    _bg.dispose();
    _heart.dispose();
    _dragX.dispose();
    _menu.dispose();
    _breathe.dispose();
    _tint.dispose();
    super.dispose();
  }

  // ── обложка сменилась: избранное + цвет фона ────────────────────────────
  void _onNow() {
    // «Живой» фон крутим только когда что-то играет (батарея + чтобы тесты
    // с pumpAndSettle не висели на бесконечной анимации).
    if (_p.now.value != null) {
      if (!_bg.isAnimating) _bg.repeat(reverse: true);
    } else {
      _bg.stop();
    }
    _syncFav();
    _syncTint();
    if (mounted) setState(() {}); // волна/название
  }

  Future<void> _syncFav() async {
    final cur = _p.now.value;
    if (cur == null || cur.id == _favTrackId) return;
    final v = await ref.read(downloadsProvider).favorite(cur.id);
    if (!mounted) return;
    setState(() {
      _favTrackId = cur.id;
      _fav = v;
    });
  }

  Future<void> _syncTint() async {
    final cur = _p.now.value;
    if (cur == null) return;
    final img = coverImageProvider(cur.id, cur.coverPath);
    final immediate = CoverPalette.cached(img);
    if (immediate != null) {
      _tint.value = immediate;
      return;
    }
    final c = await CoverPalette.of(img);
    if (mounted && _p.now.value?.id == cur.id) _tint.value = c;
  }

  // ── первый запуск: показать инструкцию один раз ────────────────────────
  Future<void> _maybeShowHelpFirstRun() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final marker = File('${dir.path}/player_help_seen');
      if (marker.existsSync()) return;
      marker.writeAsStringSync('1');
      if (mounted) setState(() => _showHelp = true);
    } catch (_) {
      // не смогли записать метку — просто не показываем авто-подсказку
    }
  }

  // ── действия ──────────────────────────────────────────────────────────
  Future<void> _toggle() => _p.toggle();

  Future<void> _like() async {
    final cur = _p.now.value;
    if (cur == null) return;
    _heart.forward(from: 0);
    if (!_fav) {
      setState(() => _fav = true);
      await ref.read(downloadsProvider).setFavorite(cur.id, true);
      _toast('Добавил в любимое');
    }
  }

  Future<void> _toggleFavButton() async {
    final cur = _p.now.value;
    if (cur == null) return;
    final v = !_fav;
    setState(() => _fav = v);
    await ref.read(downloadsProvider).setFavorite(cur.id, v);
    if (v) _heart.forward(from: 0);
  }

  void _swipeNext() {
    _toast('Дальше');
    _p.next();
  }

  void _swipePrev() {
    _toast('Назад');
    _p.prev();
  }

  Future<void> _wrongVersion(NowPlaying now) async {
    await ref.read(downloadsProvider).delete(now.id, reason: 'wrong_version');
    if (!mounted) return;
    await _p.next();
    _toast('Убрал — сервер поищет версию получше');
  }

  // Причины удаления — чтобы потом различать объективно плохие песни
  // (качество, не музыка) и просто не по вкусу (05.09.2026). «Не та версия»
  // вынесена в отдельный пункт меню, здесь её нет.
  static const _deleteReasons = <String, String>{
    'dislike': 'Не нравится песня',
    'bad_quality': 'Плохое качество звука',
    'not_music': 'Это не музыка (подкаст, интервью)',
    'tired': 'Просто надоела',
    'other': 'Другая причина',
  };

  /// Спросить причину и убрать трек с телефона (и с сервера — обычным синком).
  Future<void> _confirmDelete(NowPlaying now) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Afisha.surfaceHi,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Почему убираешь песню?',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            for (final e in _deleteReasons.entries)
              ListTile(
                title: Text(e.value,
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    await ref.read(downloadsProvider).delete(now.id, reason: reason);
    if (!mounted) return;
    await _p.next();
    _toast('Убрал с телефона');
  }

  Future<void> _hideArtist(NowPlaying now) async {
    final artist = now.artist;
    await ref
        .read(syncProvider)
        .record('hide_artist', payload: {'artist': artist});
    if (!mounted) return;
    await _p.next();
    _undo('Скрыл «$artist» из Потока', () async {
      await ref
          .read(syncProvider)
          .record('unhide_artist', payload: {'artist': artist});
    });
  }

  Future<void> _weight(NowPlaying now, {required bool more}) async {
    await ref
        .read(syncProvider)
        .record(more ? 'more_like' : 'less_like', trackId: now.id);
    if (!mounted) return;
    if (!more) await _p.next();
    _undo(more ? 'Буду чаще ставить похожее' : 'Буду реже ставить похожее',
        () async {
      await ref
          .read(syncProvider)
          .record(more ? 'less_like' : 'more_like', trackId: now.id);
    });
  }

  Future<void> _radio(NowPlaying now) async {
    if (_p.radio.value) {
      await _p.stopRadio();
      _toast('Радио выключил');
      return;
    }
    final all = await ref.read(downloadsProvider).list();
    if (all.length < 2) return;
    final ids = [
      for (final t in all)
        if (t.id != now.id) t.id,
    ];
    try {
      final res = await ref
          .read(apiProvider)
          .streamOrder(seedId: now.id, candidateIds: ids);
      if (!res.reordered) {
        _toast('У этой песни нет звукового отпечатка — похожее не подобрать');
        return;
      }
      final byId = {for (final t in all) t.id: t};
      final tail = <NowPlaying>[
        for (final id in res.ids)
          if (byId[id] case final t?)
            NowPlaying(
              id: t.id,
              title: t.title,
              artist: t.artist,
              path: t.path,
              coverPath: t.coverPath,
            ),
      ];
      if (tail.isEmpty || !mounted) return;
      await _p.setSimilarTail(tail);
      _toast('Дальше — похожее по звуку');
    } catch (_) {
      _toast('Сервер не ответил — радио не собралось');
    }
  }

  // ── подсказки/сообщения ───────────────────────────────────────────────
  void _toast(String text) {
    if (!mounted) return;
    setState(() => _toastText = text);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1700), () {
      if (mounted) setState(() => _toastText = null);
    });
  }

  void _undo(String text, Future<void> Function() onUndo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: 'Отменить',
        onPressed: () {
          onUndo();
          _toast('Отменил');
        },
      ),
    ));
  }

  String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ── сборка ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: _p.now,
      builder: (context, now, _) {
        if (now == null) {
          return widget.emptyState ??
              const Center(
                child: Text('Ничего не играет',
                    style: TextStyle(color: Afisha.inkDim)),
              );
        }
        final img = coverImageProvider(now.id, now.coverPath);
        return ValueListenableBuilder<Color>(
          valueListenable: _tint,
          builder: (context, tint, _) => Stack(
            key: ValueKey(now.id),
            fit: StackFit.expand,
            children: [
              _LivingBackdrop(image: img, anim: _bg, tint: tint),
              SafeArea(
                child: Column(
                  children: [
                    _topBar(now),
                    const Spacer(),
                    _coverArea(now, img),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 26),
                      child: Text(now.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 23,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(height: 4),
                    Text(now.artist,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 13)),
                    const SizedBox(height: 18),
                    _Wave(controller: _p, tint: tint, seedText: now.id),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 26),
                      child: _times(),
                    ),
                    const SizedBox(height: 12),
                    _transport(),
                    const SizedBox(height: 16),
                    _queueHandle(now),
                  ],
                ),
              ),
              _heartPop(),
              _toastPlashka(),
              if (_menuOpen) _actionsOverlay(now),
              if (_showHelp) _HelpOverlay(onClose: () => setState(() => _showHelp = false)),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar(NowPlaying now) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 10, 0),
        child: Row(
          children: [
            if (widget.onDismiss != null)
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
              )
            else
              const SizedBox(width: 12),
            const Spacer(),
            Text('ПОТОК',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    letterSpacing: 2)),
            const Spacer(),
            IconButton(
              onPressed: () => setState(() => _showHelp = true),
              icon: Icon(Icons.help_outline,
                  color: Colors.white.withValues(alpha: 0.75), size: 20),
            ),
            GestureDetector(
              onTap: () => _whySheet(now),
              child: ValueListenableBuilder<bool>(
                valueListenable: _p.radio,
                builder: (_, on, _) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('∞',
                          style: TextStyle(
                              color: on ? Afisha.lime : Colors.white70,
                              fontSize: 15,
                              height: 1)),
                      const SizedBox(width: 6),
                      const Text('радио',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _coverArea(NowPlaying now, ImageProvider? img) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onDoubleTap: _like,
      onLongPress: _openMenu,
      onHorizontalDragUpdate: (d) {
        _dragX.value = (_dragX.value + d.delta.dx).clamp(-150.0, 150.0);
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dragX.value <= -60 || v < -600) {
          _swipeNext();
        } else if (_dragX.value >= 60 || v > 600) {
          _swipePrev();
        }
        _dragX.animateTo(0,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 300) {
          widget.onDismiss?.call();
        } else if (v < -300) {
          _openQueue(now);
        }
      },
      child: AnimatedBuilder(
        animation: _breathe,
        builder: (context, child) {
          // 1.00 → 1.024 → 1.00, медленно, пока играет музыка.
          final s = 1.0 + 0.024 * Curves.easeInOut.transform(_breathe.value);
          return Transform.scale(scale: s, child: child);
        },
        child: AnimatedBuilder(
          animation: _dragX,
          builder: (context, child) => Transform.translate(
            offset: Offset(_dragX.value, 0),
            child: Transform.rotate(angle: _dragX.value / 2600, child: child),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Afisha.surfaceHi,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 40,
                      offset: const Offset(0, 16)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: CoverArt(trackId: now.id, localPath: now.coverPath),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _times() => ValueListenableBuilder<Duration>(
        valueListenable: _p.duration,
        builder: (_, dur, _) => ValueListenableBuilder<Duration>(
          valueListenable: _p.position,
          builder: (_, pos, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_mmss(pos),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
              Text(_mmss(dur),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ),
      );

  Widget _transport() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 40,
            color: Colors.white,
            icon: const Icon(Icons.skip_previous),
            onPressed: _p.prev,
          ),
          const SizedBox(width: 14),
          ValueListenableBuilder<bool>(
            valueListenable: _p.playing,
            builder: (_, pl, _) => GestureDetector(
              onTap: _p.toggle,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Afisha.lime,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(pl ? Icons.pause : Icons.play_arrow,
                    color: Colors.black, size: 34),
              ),
            ),
          ),
          const SizedBox(width: 14),
          IconButton(
            iconSize: 40,
            color: Colors.white,
            icon: const Icon(Icons.skip_next),
            onPressed: _p.next,
          ),
          const SizedBox(width: 10),
          IconButton(
            iconSize: 26,
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                color: _fav ? Afisha.lime : Colors.white70),
            onPressed: _toggleFavButton,
          ),
          Builder(
            builder: (context) => IconButton(
              iconSize: 24,
              icon: const Icon(Icons.delete_outline, color: Colors.white70),
              onPressed: () {
                final now = _p.now.value;
                if (now != null) _confirmDelete(now);
              },
            ),
          ),
        ],
      );

  Widget _queueHandle(NowPlaying now) {
    final q = _p.queueView;
    final i = _p.currentIndex;
    final nextTitle = (i >= 0 && i + 1 < q.length)
        ? '${q[i + 1].title} — ${q[i + 1].artist}'
        : 'больше ничего';
    return GestureDetector(
      onTap: () => _openQueue(now),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -100) _openQueue(now);
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.queue_music, color: Colors.white54, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Дальше: $nextTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13.5)),
                ),
                const Icon(Icons.keyboard_arrow_up, color: Colors.white54),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _heartPop() => IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _heart,
            builder: (context, _) {
              final t = _heart.value;
              if (t == 0) return const SizedBox.shrink();
              final scale = 0.6 + Curves.easeOut.transform(t) * 0.9;
              final opacity = t < 0.5 ? t * 2 : (1 - t) * 2;
              return Opacity(
                opacity: opacity.clamp(0, 1),
                child: Transform.scale(
                  scale: scale,
                  child: const Icon(Icons.favorite,
                      color: Afisha.lime, size: 120),
                ),
              );
            },
          ),
        ),
      );

  Widget _toastPlashka() => SafeArea(
        child: IgnorePointer(
          child: Align(
            alignment: const Alignment(0, -0.72),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _toastText == null
                  ? const SizedBox.shrink()
                  : Container(
                      key: ValueKey(_toastText),
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12)),
                      ),
                      child: Text(_toastText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ),
            ),
          ),
        ),
      );

  // ── меню действий по долгому нажатию ──────────────────────────────────
  // Всё меню появляется одним плавным движением (обложка уменьшается, панель
  // действий подъезжает снизу с лёгким «доводом»). Без размытия фона на
  // каждый кадр — оно роняло кадры на телефоне (Alex 18604: «кусками»).
  Widget _actionsOverlay(NowPlaying now) {
    final items = <(IconData, String, VoidCallback)>[
      _p.radio.value
          ? (Icons.radio_button_checked, 'радио\nвыкл', () => _radio(now))
          : (Icons.radio, 'радио\nпо этой', () => _radio(now)),
      (Icons.tune, 'не хочу\nэту версию', () => _wrongVersion(now)),
      (Icons.person_off, 'скрыть\nисполнителя', () => _hideArtist(now)),
      (Icons.trending_up, 'больше\nтакого', () => _weight(now, more: true)),
      (Icons.trending_down, 'меньше\nтакого', () => _weight(now, more: false)),
      (Icons.info_outline, 'почему\nиграет', () => _whySheet(now)),
      (Icons.delete_outline, 'удалить', () => _confirmDelete(now)),
    ];

    Widget action((IconData, String, VoidCallback) it) => GestureDetector(
          onTap: () {
            _closeMenu();
            it.$3();
          },
          child: SizedBox(
            width: 88,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.22)),
                  ),
                  child: Icon(it.$1, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 7),
                Text(it.$2,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 11.5)),
              ],
            ),
          ),
        );

    final panel = SafeArea(
      child: Column(
        children: [
          const Spacer(flex: 2),
          SizedBox(
            width: 200,
            child: CoverArt(trackId: now.id, localPath: now.coverPath),
          ),
          const Spacer(flex: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 16,
              children: [for (final it in items) action(it)],
            ),
          ),
        ],
      ),
    );

    return Positioned.fill(
      child: GestureDetector(
        onTap: _closeMenu,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _menu, curve: Curves.easeOut),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xE60B0B0B)),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(
                  CurvedAnimation(parent: _menu, curve: Curves.easeOutCubic)),
              child: panel,
            ),
          ),
        ),
      ),
    );
  }

  void _whySheet(NowPlaying now) {
    final radioOn = _p.radio.value;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Afisha.surfaceHi,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Почему это играет',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text(
                radioOn
                    ? 'Радио по песне: дальше идут вещи, похожие по звуку на ту, '
                        'с которой ты включил радио.'
                    : 'Поток играет твою скачанную музыку вперемешку. Лайки, '
                        '«больше/меньше такого» и скрытые исполнители со временем '
                        'подстроят порядок под тебя.',
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openQueue(NowPlaying now) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Afisha.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        final q = _p.queueView;
        final i = _p.currentIndex;
        final upcoming = <MapEntry<int, NowPlaying>>[
          for (var k = 0; k < q.length; k++)
            if (k > i) MapEntry(k, q[k]),
        ];
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Дальше',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                if (upcoming.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Очередь пустая',
                        style: TextStyle(color: Afisha.inkDim)),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: upcoming.length,
                      itemBuilder: (_, x) {
                        final e = upcoming[x];
                        return ListTile(
                          leading: CoverThumb(
                            path: e.value.coverPath,
                            url: coverUrlFor(e.value.id),
                            size: 44,
                          ),
                          title: Text(e.value.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(e.value.artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            Navigator.pop(context);
                            _p.jumpTo(e.key);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── живой фон: размытая обложка тихо плывёт, поверх — цвет и затемнение ────
class _LivingBackdrop extends StatelessWidget {
  const _LivingBackdrop({
    required this.image,
    required this.anim,
    required this.tint,
  });

  final ImageProvider? image;
  final Animation<double> anim;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Afisha.bg),
        if (image != null)
          AnimatedBuilder(
            animation: anim,
            builder: (context, _) {
              final t = Curves.easeInOut.transform(anim.value);
              return Transform.scale(
                scale: 1.18 + t * 0.06,
                child: Transform.translate(
                  offset: Offset((t - 0.5) * 26, (t - 0.5) * 18),
                  child: ImageFiltered(
                    imageFilter:
                        ui.ImageFilter.blur(sigmaX: 42, sigmaY: 42),
                    child: Image(
                      image: image!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: Afisha.bg),
                    ),
                  ),
                ),
              );
            },
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(alpha: 0.45),
                Colors.black.withValues(alpha: 0.62),
                Colors.black,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

// ── волновой ползунок перемотки ─────────────────────────────────────────
class _Wave extends StatelessWidget {
  const _Wave({
    required this.controller,
    required this.tint,
    required this.seedText,
  });

  final PlayerController controller;
  final Color tint;
  final String seedText;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.duration,
      builder: (_, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: controller.position,
        builder: (_, pos, _) {
          final total = dur.inMilliseconds;
          final frac =
              total <= 0 ? 0.0 : (pos.inMilliseconds / total).clamp(0.0, 1.0);
          void seekAt(double dx, double w) {
            if (total <= 0 || w <= 0) return;
            controller
                .seek(Duration(milliseconds: (total * (dx / w).clamp(0, 1)).round()));
          }

          return LayoutBuilder(
            builder: (context, c) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => seekAt(d.localPosition.dx, c.maxWidth),
              onHorizontalDragUpdate: (d) =>
                  seekAt(d.localPosition.dx, c.maxWidth),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WavePainter(
                    frac,
                    _seed(seedText),
                    played: tint == Afisha.surfaceHi ? Afisha.lime : tint,
                    rest: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  int _seed(String s) => s.codeUnits.fold<int>(7, (p, c) => (p * 31 + c) & 0x7fffffff);
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.progress, this.seed, {required this.played, required this.rest});
  final double progress;
  final int seed;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    const n = 58;
    final gap = size.width / n;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      final h = size.height * (0.16 + rnd.nextDouble() * 0.8);
      final x = i * gap + gap / 2;
      final p = Paint()
        ..color = (i / n) <= progress ? played : rest
        ..strokeWidth = gap * 0.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), p);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.progress != progress || old.played != played;
}

// ── инструкция «как пользоваться» внутри приложения ─────────────────────
class _HelpOverlay extends StatelessWidget {
  const _HelpOverlay({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String g, String what) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Afisha.lime, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                          text: '$g — ',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      TextSpan(
                          text: what,
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
            ],
          ),
        );

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          color: Colors.black.withValues(alpha: 0.82),
          alignment: Alignment.center,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            decoration: BoxDecoration(
              color: Afisha.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Afisha.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Как пользоваться',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('Всё управление — по обложке',
                    style: TextStyle(color: Afisha.inkDim, fontSize: 12)),
                const SizedBox(height: 14),
                row(Icons.touch_app, 'Тап', 'пауза или играть'),
                row(Icons.favorite, 'Двойной тап', 'нравится'),
                row(Icons.swipe, 'Смахнуть вбок', 'следующая / предыдущая песня'),
                row(Icons.keyboard_arrow_up, 'Смахнуть вверх', 'очередь «Дальше»'),
                row(Icons.keyboard_arrow_down, 'Смахнуть вниз', 'свернуть плеер'),
                row(Icons.more_horiz, 'Долгое нажатие',
                    'меню: радио, не хочу эту версию, скрыть исполнителя, больше/меньше такого, удалить, почему играет'),
                row(Icons.graphic_eq, 'Вести по волне', 'перемотка'),
                row(Icons.delete_outline, 'Корзина внизу',
                    'убрать песню с телефона (спросит причину)'),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: onClose,
                    child: const Text('Понятно'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

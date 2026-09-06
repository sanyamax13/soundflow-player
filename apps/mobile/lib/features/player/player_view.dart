import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import 'cover_backdrop.dart';
import 'player_controller.dart';

/// Тело полноэкранного плеера: обложка целиком по центру + её размытая копия
/// фоном (вариант «с размытым фоном», Alex 05.09.2026 — раньше обложка
/// растягивалась на весь экран и у квадратных резались края), поверх нижней
/// части — градиент и управление (перемотка, назад/вперёд, пауза, перемешивание,
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

  // Причины удаления (05.09.2026, просьба Alex): чтобы потом было видно,
  // какие песни объективно плохие (качество, не та версия, не музыка), а
  // какие просто не по вкусу — это разные сигналы для будущей настройки
  // фильтров/подбора, их стоит различать сразу, не задним числом.
  static const _deleteReasons = <String, String>{
    'dislike': 'Не нравится песня',
    'bad_quality': 'Плохое качество звука',
    'wrong_version': 'Не та версия (кавер, ремикс и т.п.)',
    'not_music': 'Это не музыка (подкаст, интервью)',
    'tired': 'Просто надоела',
    'other': 'Другая причина',
  };
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

  /// Спросить причину и убрать трек с телефона (и с сервера — через обычную
  /// синхронизацию, как и раньше). Играющий сейчас трек — переходим на
  /// следующий, чтобы не залипнуть на убранном.
  Future<void> _confirmDelete(NowPlaying now) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Afisha.surfaceHi,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Почему убираешь песню?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final e in _deleteReasons.entries)
              ListTile(
                title: Text(
                  e.value,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    await AppScope.of(context).downloads.delete(now.id, reason: reason);
    if (!mounted) return;
    await _p.next();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Убрал с телефона')));
  }

  String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// «Не та версия» одним тапом: убрать этот трек (причина wrong_version —
  /// сервер потом сам подтянет другую версию, см. deleteAndReacquire) и
  /// перейти к следующему. Без листа причин, в отличие от корзины.
  Future<void> _replaceVersion(NowPlaying now) async {
    final messenger = ScaffoldMessenger.of(context);
    await AppScope.of(context).downloads.delete(now.id, reason: 'wrong_version');
    if (!mounted) return;
    await _p.next();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Убрал — сервер поищет версию получше')),
    );
  }

  /// «Радио по этой песне»: спросить у сервера порядок скачанных треков по
  /// близости звучания к текущему и поставить их в хвост очереди. Текущая
  /// не прерывается. Сервер молчит / у трека нет отпечатка — очередь как была.
  Future<void> _radio(NowPlaying now) async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final all = await scope.downloads.list();
    if (all.length < 2) return;
    final ids = [
      for (final t in all)
        if (t.id != now.id) t.id,
    ];
    try {
      final ordered = await scope.api.streamOrder(seedId: now.id, candidateIds: ids);
      final byId = {for (final t in all) t.id: t};
      final tail = <NowPlaying>[
        for (final id in ordered)
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
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Дальше — похожее по звуку')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Сервер не ответил — радио не собралось')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: _p.now,
      builder: (context, now, _) {
        if (now == null) {
          return widget.emptyState ??
              const Center(
                child: Text(
                  'Ничего не играет',
                  style: TextStyle(color: Afisha.inkDim),
                ),
              );
        }
        return Stack(
          key: ValueKey(now.id),
          fit: StackFit.expand,
          children: [
            // Обложка целиком по центру + её размытая копия фоном. Локальный
            // файл у скачанных, иначе — адрес обложки на сервере (у старой
            // перенесённой библиотеки локальной нет, сервер достаёт из mp3
            // или из iTunes/Deezer/нарисованных). Нет нигде — заглушка с нотой.
            CoverBackdrop(trackId: now.id, localPath: now.coverPath),
            // Градиент снизу — чтобы текст и кнопки читались на любой обложке.
            // К самому низу отпускаем обратно (0.7), чтобы под прозрачным
            // меню был виден цвет обложки, а не глухой чёрный (Alex 06.09.2026).
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                  stops: const [0.30, 0.82, 1.0],
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
                  // Корзина (удалить) — перенесена вниз, в ряд с остальным
                  // управлением (05.09.2026, просьба Alex): в углу до неё
                  // неудобно тянуться пальцем, что правой рукой держи телефон,
                  // что левой.
                  if (widget.onDismiss != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Colors.white,
                            ),
                            onPressed: widget.onDismiss,
                          ),
                        ],
                      ),
                    ),
                  // Обложка занимает всё свободное место сверху; название —
                  // строго под ней, не наезжает на картинку (Alex 06.09.2026).
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Center(
                        child: CoverArt(
                          trackId: now.id,
                          localPath: now.coverPath,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                    child: Column(
                      children: [
                        Text(
                          now.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          now.artist,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        // Две быстрые кнопки под названием (Alex 06.09.2026):
                        //  • «Радио по этой» — дальше в очереди пойдут песни,
                        //    похожие по звуку на текущую (сервер /stream/order).
                        //  • «Не та версия» — трек уходит с причиной
                        //    wrong_version, сервер ищет другую версию, играем
                        //    дальше. То же есть в списке причин у корзины, но
                        //    там на три тапа больше.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: _p.radio,
                              builder: (_, on, _) => _MiniAction(
                                icon: Icons.radio,
                                label: 'Радио по этой',
                                color: on ? Afisha.lime : Colors.white54,
                                onPressed: () => _radio(now),
                              ),
                            ),
                            const SizedBox(width: 4),
                            _MiniAction(
                              icon: Icons.sync_problem,
                              label: 'Не та версия',
                              color: Colors.white54,
                              onPressed: () => _replaceVersion(now),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _ProgressBar(controller: _p, label: _mmss),
                      ],
                    ),
                  ),
                  // Ряд управления. Кнопка play должна стоять РОВНО по центру
                  // экрана (05.09.2026, просьба Alex — после переезда корзины
                  // сюда шесть кнопок в общем ряду сдвигали play влево). Приём:
                  // play — фиксированный средний ребёнок, а по бокам два
                  // Expanded одинаковой ширины со своими кнопками. Сколько бы
                  // кнопок ни было слева/справа — центр не уезжает. Корзина
                  // осталась там же, у правого края.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              ValueListenableBuilder<bool>(
                                valueListenable: _p.shuffle,
                                builder: (_, sh, _) => IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    Icons.shuffle,
                                    color: sh ? Afisha.lime : Colors.white70,
                                  ),
                                  onPressed: _p.toggleShuffle,
                                ),
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                iconSize: 34,
                                color: Colors.white,
                                icon: const Icon(Icons.skip_previous),
                                onPressed: _p.prev,
                              ),
                            ],
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: _p.playing,
                          builder: (_, pl, _) => IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 64,
                            color: Afisha.lime,
                            icon: Icon(
                              pl
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                            ),
                            onPressed: _p.toggle,
                          ),
                        ),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                iconSize: 34,
                                color: Colors.white,
                                icon: const Icon(Icons.skip_next),
                                onPressed: _p.next,
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Icon(
                                  _fav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: _fav ? Afisha.lime : Colors.white70,
                                ),
                                onPressed: _toggleFav,
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white70,
                                ),
                                onPressed: () => _confirmDelete(now),
                              ),
                            ],
                          ),
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

/// Мелкая кнопка-действие под названием трека (иконка + подпись, без фона).
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          final value = total <= 0
              ? 0.0
              : pos.inMilliseconds.clamp(0, total).toDouble();
          return Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: value,
                  max: total <= 0 ? 1 : total.toDouble(),
                  activeColor: Afisha.lime,
                  inactiveColor: Colors.white24,
                  onChanged: total <= 0
                      ? null
                      : (v) =>
                            controller.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label(pos),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      label(dur),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
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

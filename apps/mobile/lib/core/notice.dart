import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'solar.dart';

import 'theme.dart';

/// Единая «плашка» сообщений как на iPhone (Alex TG 20167, 20.09.2026: «красивую
/// плашечку, как на айфонах, а не просто что-то по середине экрана появляется
/// и исчезает»). Выезжает сверху, скруглённая, с размытым фоном и значком слева,
/// уходит сама (или смахиванием вверх). Заменяет и серые снэкбары снизу, и
/// «пузырь» посреди плеера.
///
/// Показывать — [Notice.show] откуда угодно, контекст не нужен. Рисует
/// [NoticeHost], он стоит над всем приложением (см. `MaterialApp.builder` в
/// main.dart), поэтому плашка видна и поверх экранов, и поверх окон-диалогов.
enum NoticeKind { info, done, removed, warn, error }

class NoticeAction {
  const NoticeAction(this.label, this.onPressed, {this.primary = true});
  final String label;
  final VoidCallback onPressed;

  /// Главная кнопка — лаймовая; остальные тише.
  final bool primary;
}

class NoticeData {
  NoticeData({
    required this.title,
    this.subtitle,
    this.kind = NoticeKind.info,
    this.actions = const [],
    this.duration,
  }) : id = _next++;

  static int _next = 0;

  final int id;
  final String title;
  final String? subtitle;
  final NoticeKind kind;
  final List<NoticeAction> actions;

  /// Сколько висит. null — по умолчанию: 3 с; с кнопками — 9 с, чтобы успеть
  /// прочитать и нажать.
  final Duration? duration;

  Duration get life =>
      duration ??
      (actions.isEmpty
          ? const Duration(milliseconds: 3000)
          : const Duration(seconds: 9));
}

class Notice {
  Notice._();

  /// Что сейчас показываем (null — ничего). Слушает [NoticeHost].
  static final ValueNotifier<NoticeData?> current = ValueNotifier<NoticeData?>(
    null,
  );

  static NoticeData show(
    String title, {
    String? subtitle,
    NoticeKind kind = NoticeKind.info,
    List<NoticeAction> actions = const [],
    Duration? duration,
  }) {
    final d = NoticeData(
      title: title,
      subtitle: subtitle,
      kind: kind,
      actions: actions,
      duration: duration,
    );
    current.value = d;
    return d;
  }

  /// Убрать плашку. [id] — только если висит именно она (чтобы таймер старой
  /// плашки не смёл новую).
  static void hide([int? id]) {
    if (id != null && current.value?.id != id) return;
    current.value = null;
  }
}

/// Ключ главного навигатора — плашка живёт выше него, а кнопкам на ней иногда
/// нужно открыть экран (например «Проверить связь»).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Ставится в `MaterialApp.builder`: рисует [Notice.current] поверх [child].
class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.child});

  final Widget child;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<Offset> _slide;

  NoticeData? _shown;
  Timer? _timer;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      reverseDuration: const Duration(milliseconds: 300),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1.6), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _c,
            // Пружина при появлении, плавный уход вверх за 300 мс (разбор Gemini 26.09.2026).
            curve: const ElasticOutCurve(0.9),
            reverseCurve: Curves.easeInOut,
          ),
        );
    Notice.current.addListener(_onChange);
    if (Notice.current.value != null) _onChange();
  }

  @override
  void dispose() {
    Notice.current.removeListener(_onChange);
    _timer?.cancel();
    // Окно приложения закрылось — висевшую плашку не переносим «в следующую
    // жизнь» (в тестах она иначе торчала бы в соседнем тесте).
    Notice.current.value = null;
    _c.dispose();
    super.dispose();
  }

  void _onChange() {
    final d = Notice.current.value;
    _timer?.cancel();
    if (d == null) {
      _c.reverse().whenComplete(() {
        if (mounted && Notice.current.value == null) {
          setState(() => _shown = null);
        }
      });
      return;
    }
    setState(() {
      _shown = d;
      _drag = 0;
    });
    _c.forward();
    _timer = Timer(d.life, () => Notice.hide(d.id));
  }

  void _onDragEnd(DragEndDetails e) {
    final v = e.primaryVelocity ?? 0;
    if (_drag < -28 || v < -350) {
      Notice.hide(_shown?.id);
    } else {
      setState(() => _drag = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _shown;
    return Stack(
      children: [
        widget.child,
        if (d != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: _c,
                  curve: const Interval(0, 0.6),
                ),
                child: Transform.translate(
                  offset: Offset(0, math.min(0, _drag)),
                  // Плашка без кнопок — просто подсказка: касания проходят
                  // сквозь неё (в плеере под ней кнопки «радио», «назад»).
                  // С кнопками — нажимается и смахивается вверх.
                  child: d.actions.isEmpty
                      ? IgnorePointer(
                          child: NoticeCard(key: ValueKey(d.id), data: d),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: (e) =>
                              setState(() => _drag += e.delta.dy),
                          onVerticalDragEnd: _onDragEnd,
                          child: NoticeCard(
                            key: ValueKey(d.id),
                            data: d,
                            onAction: () => Notice.hide(d.id),
                          ),
                        ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Сама плашка (вынесена отдельно, чтобы её можно было показать в тесте/на картинке).
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.data, this.onAction});

  final NoticeData data;
  final VoidCallback? onAction;

  static const _radius = 24.0;

  ({IconData icon, Color bg, Color fg}) _look() => switch (data.kind) {
    NoticeKind.done => (
      icon: SolarBold.checkCircle,
      bg: const Color(0xFF34C759),
      fg: Colors.white,
    ),
    NoticeKind.removed => (
      icon: SolarOutline.trashBinTrash,
      bg: const Color(0xFFFF453A),
      fg: Colors.white,
    ),
    NoticeKind.warn => (
      icon: SolarBold.dangerCircle,
      bg: const Color(0xFFFF9F0A),
      fg: Colors.black,
    ),
    NoticeKind.error => (
      icon: SolarOutline.cloudCross,
      bg: const Color(0xFFFF453A),
      fg: Colors.white,
    ),
    NoticeKind.info => (
      icon: SolarBold.soundwave,
      bg: Afisha.lime,
      fg: Colors.black,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.viewPaddingOf(context).top;
    final look = _look();
    final sub = data.subtitle;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, top + 8, 12, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_radius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_radius),
                  child: BackdropFilter(
                    // Стекло: то, что под плашкой, видно размытым (Black 60% + Blur 40,
                    // разбор Gemini 26.09.2026) — было почти глухое 90%.
                    filter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(_radius),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                          width: 0.8,
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: look.bg,
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  look.icon,
                                  color: look.fg,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      data.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        height: 1.25,
                                        fontWeight: FontWeight.w600,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                    if (sub != null && sub.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        sub,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.68,
                                          ),
                                          fontSize: 13,
                                          height: 1.3,
                                          fontWeight: FontWeight.w400,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (data.actions.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                for (final a in data.actions)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: _ActionButton(
                                      action: a,
                                      onDone: onAction,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, this.onDone});

  final NoticeAction action;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final primary = action.primary;
    return Material(
      color: primary ? Afisha.lime : Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          onDone?.call();
          action.onPressed();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            action.label,
            style: TextStyle(
              color: primary ? Colors.black : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

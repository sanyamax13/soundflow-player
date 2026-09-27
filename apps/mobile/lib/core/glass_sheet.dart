import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Единый вид всех всплывающих окон (27.09.2026, разбор Gemini и Алисы, Alex «делай»): только
/// шторка снизу — в машине до низа дотянуться проще, окон посреди экрана больше нет. Тёмное стекло
/// с размытием, верхние углы 32, полоска-ручка сверху, по высоте — по содержимому (не больше 85%
/// экрана, дальше прокрутка). Закрыть — смахнуть вниз или тап мимо.
Future<T?> showGlassSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    isScrollControlled: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF121214).withValues(alpha: 0.78),
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    Flexible(child: builder(ctx)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Заголовок шторки (и необязательный пояснительный текст под ним).
class GlassSheetTitle extends StatelessWidget {
  const GlassSheetTitle(this.title, {super.key, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Afisha.ink)),
            if (body != null) ...[
              const SizedBox(height: 10),
              Text(body!,
                  style: TextStyle(fontSize: 16, height: 1.4, color: Colors.white.withValues(alpha: 0.65))),
            ],
          ],
        ),
      );
}

/// Крупная кнопка-таблетка 64pt для шторок.
class GlassSheetButton extends StatelessWidget {
  const GlassSheetButton({super.key, required this.label, required this.onTap, this.kind = GlassButtonKind.plain});

  final String label;
  final VoidCallback onTap;
  final GlassButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      GlassButtonKind.lime => (Afisha.lime, Colors.black),
      GlassButtonKind.danger => (const Color(0xFFFF3B30), Colors.white),
      GlassButtonKind.plain => (Colors.white.withValues(alpha: 0.10), Afisha.ink),
    };
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(32),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Center(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: fg)),
          ),
        ),
      ),
    );
  }
}

enum GlassButtonKind { plain, lime, danger }

/// Вопрос-подтверждение шторкой. [danger] — необратимое (удалить, стереть): «Отмена» залита лаймом
/// слева (палец идёт к безопасному), действие красное справа. Обычное — «Отмена» серая, действие лайм.
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  String? body,
  required String okLabel,
  bool danger = false,
}) async {
  final ok = await showGlassSheet<bool>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSheetTitle(title, body: body),
        Row(
          children: [
            Expanded(
              child: GlassSheetButton(
                label: 'Отмена',
                kind: danger ? GlassButtonKind.lime : GlassButtonKind.plain,
                onTap: () => Navigator.pop(ctx, false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassSheetButton(
                label: okLabel,
                kind: danger ? GlassButtonKind.danger : GlassButtonKind.lime,
                onTap: () {
                  danger ? HapticFeedback.heavyImpact() : HapticFeedback.selectionClick();
                  Navigator.pop(ctx, true);
                },
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return ok ?? false;
}

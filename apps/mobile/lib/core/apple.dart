import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:solar_icons/solar_icons.dart';

import 'theme.dart';

/// Общие кирпичики оформления «как у Apple» (Alex TG 20345, 21.09.2026):
/// сгруппированный список на серых плашках, ряд с цветным значком, переключатель
/// «сегменты». Цвета и радиусы — из [Afisha] (тёмная тема iOS).
///
/// 25.09.2026 (Alex TG, «переделаем всё приложение в таком стиле» — после
/// разбора причин удаления с матовым стеклом): [AppleSection] заматирована —
/// полупрозрачная плашка с размытием фона вместо сплошной серой, крупнее
/// скругление (синтез направления iOS «Liquid Glass» и более крупных форм
/// One UI, макетов ни той ни другой версии у меня нет — собственная
/// добросовестная догадка, не копия). [AppleRow] не трогал — раскладка
/// строки (значок/текст/шеврон) работает одинаково в обоих стилях.

/// Крупный заголовок экрана вкладки, как в iOS (34 pt, жирный). Отступы —
/// на стороне экрана: у всех вкладок заголовок стоит на одном и том же месте.
class AppleLargeTitle extends StatelessWidget {
  const AppleLargeTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontSize: 34,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
      color: Afisha.ink,
    ),
  );
}

/// Группа рядов на скруглённой серой плашке с тонкими разделителями,
/// сверху необязательная подпись, снизу — пояснение (как в «Настройках» iPhone).
class AppleSection extends StatelessWidget {
  const AppleSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.dividerInset = 16,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;

  /// Отступ разделителя слева: 16 для рядов без значка, 58 — со значком.
  final double dividerInset;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: dividerInset,
            color: Afisha.sep,
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 7),
              child: Text(
                header!,
                style: const TextStyle(
                  color: Afisha.inkDim,
                  fontSize: 13,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  // 25.09.2026 (Alex TG, «на чёрном фоне стекло почти не видно
                  // — стоит добиваться эффекта»): на сплошном чёрном фоне
                  // размытие само по себе ничего не даёт (размытый чёрный —
                  // тот же чёрный), поэтому стекло держится на своих двух
                  // приметах — светлее самого фона (0.08 → 0.11) и блик
                  // сверху-слева, как у настоящего стекла, которое ловит свет
                  // даже когда за ним нет ярких красок.
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.09),
                      Colors.white.withValues(alpha: 0.05),
                    ],
                    stops: const [0, 0.35, 1],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Column(children: rows),
                ),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(
                footer!,
                style: const TextStyle(
                  color: Afisha.inkDim,
                  fontSize: 13,
                  height: 1.3,
                  letterSpacing: -0.1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ряд списка: цветной значок-квадрат слева, заголовок, пояснение или значение
/// справа и стрелка «>», если ряд открывает экран. Нажатие — серое затемнение.
class AppleRow extends StatelessWidget {
  const AppleRow({
    super.key,
    required this.title,
    this.icon,
    this.iconBg = Afisha.gray,
    this.subtitle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.destructive = false,
  });

  final String title;
  final IconData? icon;
  final Color iconBg;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final hasSub = subtitle != null && subtitle!.isNotEmpty;
    final row = Padding(
      padding: EdgeInsets.fromLTRB(16, hasSub ? 9 : 7, 12, hasSub ? 9 : 7),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 30),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      letterSpacing: -0.4,
                      color: destructive ? Afisha.red : Afisha.ink,
                    ),
                  ),
                  if (hasSub)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.25,
                          letterSpacing: -0.1,
                          color: Afisha.inkDim,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              Text(
                value!,
                style: const TextStyle(
                  fontSize: 17,
                  letterSpacing: -0.4,
                  color: Afisha.inkDim,
                ),
              ),
            ],
            ?trailing,
            if (chevron) ...[
              const SizedBox(width: 6),
              const Icon(
                SolarIconsOutline.altArrowRight,
                size: 15,
                color: Afisha.chevron,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// Переключатель «сегменты» как в iOS: серая дорожка и подвижный светлый
/// бегунок под выбранным пунктом.
class AppleSegmented<T> extends StatelessWidget {
  const AppleSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  /// Значение → подпись, порядок сохраняется.
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final keys = options.keys.toList();
    final idx = keys.indexOf(selected).clamp(0, keys.length - 1);
    return Container(
      height: 34,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Afisha.groupBg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / keys.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: const Cubic(0.32, 0.72, 0, 1),
                left: w * idx,
                top: 0,
                bottom: 0,
                width: w,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF636366),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final k in keys)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (k == selected) return;
                          HapticFeedback.selectionClick();
                          onChanged(k);
                        },
                        child: Center(
                          child: Text(
                            options[k]!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              letterSpacing: -0.1,
                              fontWeight: k == selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: Afisha.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Пункт меню-шторки [showAppleActionSheet].
class SheetAction<T> {
  const SheetAction(this.value, this.label, this.icon, {this.destructive = false});

  final T value;
  final String label;
  final IconData icon;

  /// Опасное действие (удалить): красное, отделено от остальных отступом снизу
  /// списка и с сильной вибрацией при нажатии.
  final bool destructive;
}

/// Меню «•••» — нижняя шторка вместо окошка у кнопки (разбор Gemini 26.09.2026,
/// «Моя музыка»): крупные строки 64pt под палец в машине, значок 28pt, текст 18pt,
/// опасные пункты внизу, красным, после отступа. Возвращает выбранное значение.
Future<T?> showAppleActionSheet<T>(
  BuildContext context, {
  String? title,
  required List<SheetAction<T>> actions,
}) {
  final safe = actions.where((a) => !a.destructive).toList();
  final danger = actions.where((a) => a.destructive).toList();
  Widget group(BuildContext ctx, List<SheetAction<T>> list, {String? head}) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: ColoredBox(
        color: Afisha.groupBg.withValues(alpha: 0.96),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Заголовок внутри блока, по центру (вердикт Gemini 26.09.2026: над
            // плашками он «висел в пустоте»).
            if (head != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: Text(
                  head,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.55)),
                ),
              ),
              const Divider(height: 0.5, thickness: 0.5, color: Afisha.sep),
            ],
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0) const Divider(height: 0.5, thickness: 0.5, indent: 60, color: Afisha.sep),
              _SheetRow(
                action: list[i],
                onTap: () {
                  list[i].destructive ? HapticFeedback.heavyImpact() : HapticFeedback.selectionClick();
                  Navigator.pop(ctx, list[i].value);
                },
              ),
            ],
          ],
        ),
      ),
    ),
  );
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (safe.isNotEmpty) group(ctx, safe, head: title),
            if (safe.isNotEmpty && danger.isNotEmpty) const SizedBox(height: 16),
            if (danger.isNotEmpty) group(ctx, danger, head: safe.isEmpty ? title : null),
          ],
        ),
      ),
    ),
  );
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.action, required this.onTap});

  final SheetAction<Object?> action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive ? Afisha.red : Afisha.ink;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Icon(action.icon, size: 28, color: action.destructive ? Afisha.red : Afisha.lime),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

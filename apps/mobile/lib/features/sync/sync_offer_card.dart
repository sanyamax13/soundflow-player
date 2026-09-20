import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/sync_offer.dart';

/// Карточка «что ждёт на компьютере» (см. [SyncOffer]): одна строка и одна
/// кнопка вместо «Скачать музыку» и «Синхронизировать сейчас». Ничего не ждёт —
/// не занимает места (в Профиле, [showIdle], вместо неё тихая строка «всё на
/// месте»). Идёт скачивание — та же карточка показывает полоску «3 из 12» и
/// «Стоп».
class SyncOfferCard extends ConsumerWidget {
  const SyncOfferCard({super.key, this.showIdle = false});

  /// true — когда предлагать нечего, всё равно показывать строку состояния.
  final bool showIdle;

  static const _red = Color(0xFFFF453A);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.read(syncOfferProvider);
    return ListenableBuilder(
      listenable: offer,
      builder: (context, _) {
        if (offer.running) return _shell(_running(offer));
        if (offer.hasOffer) return _shell(_offer(offer), red: offer.lowSpace);
        return showIdle ? _idle(offer) : const SizedBox.shrink();
      },
    );
  }

  Widget _shell(Widget child, {bool red = false}) => Container(
    margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
    decoration: BoxDecoration(
      color: red ? _red.withValues(alpha: 0.10) : Afisha.surfaceHi,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: red ? _red.withValues(alpha: 0.55) : Afisha.line,
      ),
    ),
    child: child,
  );

  Widget _offer(SyncOffer o) {
    final p = o.preview;
    final rows = <Widget>[];
    if (p.addCount > 0) {
      rows.add(
        _row(
          icon: o.lowSpace
              ? Icons.priority_high_rounded
              : Icons.download_rounded,
          tileBg: o.lowSpace ? _red : Afisha.lime,
          tileFg: o.lowSpace ? Colors.white : Colors.black,
          title: o.addTitle,
          subtitle: o.addSubtitle,
          subtitleColor: o.lowSpace ? const Color(0xFFFF7A70) : Afisha.inkDim,
          button: 'Скачать',
          onPressed: () => o.run(adds: true, removes: false),
        ),
      );
    }
    if (p.removeCount > 0) {
      if (rows.isNotEmpty) {
        rows.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: Afisha.line),
          ),
        );
      }
      rows.add(
        _row(
          icon: Icons.delete_outline_rounded,
          tileBg: const Color(0xFF3A3A3C),
          tileFg: Colors.white,
          title: o.removeTitle,
          subtitle: o.removeSubtitle,
          subtitleColor: Afisha.inkDim,
          button: 'Стереть',
          onPressed: () => o.run(adds: false, removes: true),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _row({
    required IconData icon,
    required Color tileBg,
    required Color tileFg,
    required String title,
    required String subtitle,
    required Color subtitleColor,
    required String button,
    required VoidCallback onPressed,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: tileBg,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: tileFg, size: 23),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Afisha.ink,
                  fontSize: 14.5,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subtitleColor,
                  fontSize: 12.5,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontFamily: Afisha.fontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          onPressed: onPressed,
          child: Text(button),
        ),
      ],
    );
  }

  Widget _running(SyncOffer o) {
    final word = o.removingNow ? 'Стираю' : 'Скачиваю';
    final of = o.total == 0 ? '' : ': ${fmtInt(o.done)} из ${fmtInt(o.total)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Afisha.lime,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$word$of',
                    style: const TextStyle(
                      color: Afisha.ink,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (o.current.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      o.current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Afisha.inkDim,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            TextButton(onPressed: o.cancel, child: const Text('Стоп')),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 5,
            value: o.total == 0 ? null : o.done / o.total,
            backgroundColor: Afisha.line,
          ),
        ),
      ],
    );
  }

  Widget _idle(SyncOffer o) {
    final String text;
    if (o.lastCheckFailed) {
      text = 'Компьютер не отвечает. Открой окно SoundFlow на компьютере';
    } else if (o.checkedAt == null) {
      text = 'Проверяю…';
    } else {
      final t = o.checkedAt!;
      String two(int n) => n.toString().padLeft(2, '0');
      text = 'Всё на месте · проверено в ${two(t.hour)}:${two(t.minute)}';
    }
    return ListTile(
      leading: Icon(
        o.lastCheckFailed
            ? Icons.cloud_off_outlined
            : Icons.check_circle_outline,
        color: Afisha.inkDim,
      ),
      title: const Text('Музыка с компьютера'),
      subtitle: Text(text, style: const TextStyle(color: Afisha.inkDim)),
      onTap: () => o.refresh(announce: false),
    );
  }
}

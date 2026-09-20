import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/crash_log.dart';
import 'package:soundflow/core/format.dart';
import 'package:soundflow/core/notice.dart';

/// Плашка сообщений «как на iPhone» (Alex TG 20167) и мелкие помощники к ней.
Widget _host() => MaterialApp(
      builder: (context, child) => NoticeHost(child: child ?? const SizedBox.shrink()),
      home: const Scaffold(body: Center(child: Text('экран'))),
    );

void main() {
  tearDown(() => Notice.hide());

  testWidgets('плашка выезжает сверху, показывает текст и сама уходит', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.text('Убрал с телефона'), findsNothing);

    Notice.show('Убрал с телефона', subtitle: 'Кино — Группа крови', kind: NoticeKind.removed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Убрал с телефона'), findsOneWidget);
    expect(find.text('Кино — Группа крови'), findsOneWidget);
    // прижата к верху экрана, а не «посреди»
    expect(tester.getTopLeft(find.text('Убрал с телефона')).dy, lessThan(120));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Убрал с телефона'), findsNothing);
  });

  testWidgets('кнопка на плашке вызывает действие и убирает плашку', (tester) async {
    await tester.pumpWidget(_host());
    var taken = 0;
    Notice.show(
      'На компьютере 12 новых песен (85 МБ)',
      actions: [NoticeAction('Скачать', () => taken++), NoticeAction('Не сейчас', () {}, primary: false)],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // с кнопками висит дольше обычных 3 секунд — успеть прочитать и нажать
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Скачать'), findsOneWidget);

    await tester.tap(find.text('Скачать'));
    await tester.pumpAndSettle();
    expect(taken, 1);
    expect(find.text('Скачать'), findsNothing);
  });

  testWidgets('новая плашка заменяет старую, старый таймер её не смахивает', (tester) async {
    await tester.pumpWidget(_host());
    Notice.show('Первая');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    Notice.show('Вторая');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // 4 с от первой, но лишь 2 с от второй
    expect(find.text('Вторая'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Вторая'), findsNothing);
  });

  testWidgets('плашка с кнопками смахивается вверх', (tester) async {
    await tester.pumpWidget(_host());
    Notice.show('Готово', subtitle: 'Скачано 12', actions: [NoticeAction('Ок', () {})]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.drag(find.text('Готово'), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('Готово'), findsNothing);
  });

  // В плеере под плашкой — кнопки «радио», «назад»: подсказка без кнопок не
  // должна их перекрывать (касания проходят сквозь неё).
  testWidgets('плашка без кнопок не мешает нажимать то, что под ней', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => NoticeHost(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 30),
            child: TextButton(onPressed: () => taps++, child: const Text('радио')),
          ),
        ),
      ),
    ));
    Notice.show('Дальше — похожее по звуку');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('радио'));
    expect(taps, 1);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  test('ошибка загрузки картинки — не «сбой» приложения', () {
    final img = FlutterErrorDetails(
      exception: const SocketException('Connection timed out'),
      library: 'image resource service',
    );
    final other = FlutterErrorDetails(exception: StateError('плохо'), library: 'widgets library');
    expect(isHarmlessImageError(img), isTrue);
    expect(isHarmlessImageError(other), isFalse);
  });

  test('форматтеры: размеры, числа, склонения', () {
    expect(fmtBytes(85 * 1024 * 1024), '85 МБ');
    expect(fmtBytes((6.1 * 1024 * 1024 * 1024).round()), '6,1 ГБ');
    expect(fmtBytes(48 * 1024 * 1024 * 1024), '48 ГБ');
    expect(fmtInt(1474), '1 474');
    expect(plural(1, 'песня', 'песни', 'песен'), 'песня');
    expect(plural(3, 'песня', 'песни', 'песен'), 'песни');
    expect(plural(11, 'песня', 'песни', 'песен'), 'песен');
    expect(plural(21, 'песня', 'песни', 'песен'), 'песня');
    expect(songWord(1474), 'песни');
  });
}

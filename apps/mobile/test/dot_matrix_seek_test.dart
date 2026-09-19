import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/player/dot_matrix_seek.dart';
import 'package:soundflow/features/player/player_controller.dart';

/// В тесте нет аудиоплагина — настоящий seek ничего не делает. Запоминаем,
/// КУДА просили перемотать.
class _FakePlayer extends PlayerController {
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration to) async => seeks.add(to);
}

Future<_FakePlayer> _pump(
  WidgetTester tester, {
  DotMatrixTotal total = DotMatrixTotal.small,
  Duration position = const Duration(minutes: 1, seconds: 12),
  Duration duration = const Duration(minutes: 4, seconds: 33),
}) async {
  final player = _FakePlayer()
    ..duration.value = duration
    ..position.value = position;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(child: DotMatrixSeek(controller: player, tint: Colors.lime, total: total)),
    ),
  ));
  return player;
}

void main() {
  test('formatMmss: минуты без ведущего нуля, секунды двумя цифрами', () {
    expect(formatMmss(const Duration(seconds: 5)), '0:05');
    expect(formatMmss(const Duration(minutes: 1, seconds: 12)), '1:12');
    expect(formatMmss(const Duration(minutes: 100, seconds: 7)), '100:07');
  });

  testWidgets('показывает сколько прошло и общую длину; цифры идут за позицией', (tester) async {
    final player = await _pump(tester);
    expect(find.text('1:12'), findsOneWidget);
    expect(find.text('4:33'), findsOneWidget);

    player.position.value = const Duration(minutes: 2, seconds: 5);
    await tester.pump();
    expect(find.text('2:05'), findsOneWidget);
    expect(find.text('1:12'), findsNothing);
  });

  testWidgets('режим «убрать общую длину»: только крупные цифры', (tester) async {
    await _pump(tester, total: DotMatrixTotal.none);
    expect(find.text('1:12'), findsOneWidget);
    expect(find.text('4:33'), findsNothing);
  });

  testWidgets('режим «сколько осталось»: минус и оставшееся время', (tester) async {
    await _pump(tester, total: DotMatrixTotal.remaining);
    expect(find.text('1:12'), findsOneWidget);
    expect(find.text('−3:21'), findsOneWidget); // 4:33 - 1:12
    expect(find.text('4:33'), findsNothing);
  });

  testWidgets('тап по середине точек перематывает на середину песни', (tester) async {
    final player = await _pump(tester);
    final area = find.byKey(const ValueKey('dot_matrix_seek_area'));
    await tester.tapAt(tester.getCenter(area));
    await tester.pump();

    expect(player.seeks, hasLength(1));
    const total = Duration(minutes: 4, seconds: 33);
    expect(player.seeks.single.inMilliseconds, closeTo(total.inMilliseconds / 2, 300));
  });

  testWidgets('ведение пальцем по точкам перематывает по ходу движения', (tester) async {
    final player = await _pump(tester);
    final area = find.byKey(const ValueKey('dot_matrix_seek_area'));
    final rect = tester.getRect(area);

    // Живой палец — много мелких шагов, а не один прыжок (иначе распознаватель
    // жестов не успевает выдать обновления).
    final gesture = await tester.startGesture(Offset(rect.left + rect.width * 0.25, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(rect.left + rect.width * (0.25 + 0.05 * i), rect.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();

    expect(player.seeks, isNotEmpty);
    const total = Duration(minutes: 4, seconds: 33);
    expect(player.seeks.last.inMilliseconds, closeTo(total.inMilliseconds * 0.75, 3000));
    // перемотка вперёд по ходу движения, не назад
    expect(player.seeks.last, greaterThan(player.seeks.first));
  });

  testWidgets('длина песни неизвестна (0) — тап ничего не перематывает', (tester) async {
    final player = await _pump(tester, duration: Duration.zero, position: Duration.zero);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('dot_matrix_seek_area'))));
    await tester.pump();
    expect(player.seeks, isEmpty);
  });
}

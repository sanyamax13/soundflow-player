import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/local_taste.dart';

// Радио разнообразнее (26.09.2026, Alex «да»): исполнитель не чаще, чем через 3 песни; каждая
// 8-я позиция — «забытая» песня (не играла полгода или ни разу).
void main() {
  test('исполнитель повторяется не раньше, чем через 3 других', () {
    final ids = <String>[];
    final artists = <String, String>{};
    for (final a in ['A', 'B', 'C', 'D', 'E']) {
      for (var i = 0; i < 4; i++) {
        ids.add('$a$i');
        artists['$a$i'] = a;
      }
    }
    final vecs = {for (final id in ids) id: Float32List.fromList([1, 0])};
    for (var seed = 0; seed < 20; seed++) {
      final out = weightedShuffleByTaste(
          ids: ids, vecs: vecs, artists: artists, centroidsLongTerm: const [], centroidsRecent: const [],
          rng: Random(seed));
      expect(out.toSet(), ids.toSet(), reason: 'ни одна песня не потерялась');
      for (var i = 0; i < out.length - 3; i++) {
        final win = [for (var j = i; j < i + 4 && j < out.length - 4; j++) artists[out[j]]];
        expect(win.toSet().length, win.length, reason: 'в окне из 4 подряд исполнители разные: $win');
      }
    }
  });

  test('каждая 8-я позиция — забытая песня, порядок остальных не ломается', () {
    final ordered = [for (var i = 0; i < 24; i++) 's$i'];
    final forgotten = {'s20', 's21', 's22'};
    final out = mixForgotten(ordered, forgotten);
    expect(out.toSet(), ordered.toSet());
    expect(out[7], 's20');
    expect(out[15], 's21');
    expect(out.indexOf('s22'), 22, reason: 'к концу забытые встают и по обычному порядку');
    expect(mixForgotten(ordered, ordered.toSet()), ordered, reason: 'истории нет — порядок тот же');
    expect(mixForgotten(ordered, {}), ordered);
  });
}

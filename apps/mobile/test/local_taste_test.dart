import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/local_taste.dart';

Uint8List _vecBytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Float32List _vec(List<double> values) => Float32List.fromList(values.map((e) => e.toDouble()).toList());

void main() {
  group('bytesToVec', () {
    test('декодирует little-endian float32', () {
      final bytes = _vecBytes([1.0, 0.0, -1.0]);
      final v = bytesToVec(bytes);
      expect(v, isNotNull);
      expect(v!.length, 3);
      expect(v[0], closeTo(1.0, 1e-6));
      expect(v[2], closeTo(-1.0, 1e-6));
    });

    test('неверная длина (не кратна 4) — null', () {
      expect(bytesToVec(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('offsetInBytes не ноль — всё равно декодируется верно', () {
      final full = _vecBytes([9.0, 1.0, 2.0, 3.0]);
      final sub = Uint8List.sublistView(full, 4); // offset=4
      final v = bytesToVec(sub);
      expect(v, isNotNull);
      expect(v!.length, 3);
      expect(v[0], closeTo(1.0, 1e-6));
    });
  });

  group('orderOffline', () {
    test('ранжирует по похожести на seed + affinity к long_term центру', () {
      final seed = _vec([1, 0, 0, 0]);
      final close = _vec([0.9, 0.1, 0, 0]);
      final far = _vec([0, 0, 0, 1]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'close': close, 'far': far},
        candidateArtists: {'close': 'A', 'far': 'B'},
        centroidsLongTerm: [seed],
        centroidsRecent: const [],
      );
      expect(result.first, 'close');
    });

    test('пустые центры вкуса — не падает, сортирует по звуку', () {
      final seed = _vec([1, 0]);
      final close = _vec([0.9, 0.1]);
      final far = _vec([0, 1]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'close': close, 'far': far},
        candidateArtists: {'close': 'A', 'far': 'B'},
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      expect(result.first, 'close');
    });

    test('нулевой вектор кандидата не роняет функцию (защита от деления на ноль)', () {
      final seed = _vec([1, 0]);
      final zero = _vec([0, 0]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'zero': zero},
        candidateArtists: {'zero': 'A'},
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      expect(result, ['zero']);
    });

    test('не больше 2 подряд одного исполнителя', () {
      final seed = _vec([1, 0]);
      final vecs = {
        'a1': _vec([1, 0]), 'a2': _vec([0.99, 0.01]), 'a3': _vec([0.98, 0.02]),
        'b1': _vec([0.5, 0.5]),
      };
      final artists = {'a1': 'A', 'a2': 'A', 'a3': 'A', 'b1': 'B'};
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: vecs,
        candidateArtists: artists,
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      var run = 0;
      String? last;
      for (final id in result) {
        final artist = artists[id];
        if (artist == last) {
          run++;
        } else {
          run = 1;
          last = artist;
        }
        expect(run, lessThanOrEqualTo(2), reason: 'result=$result');
      }
    });
  });

  group('decodeCentroids', () {
    test('null — оба слоя пустые', () {
      final (longTerm, recent) = decodeCentroids(null);
      expect(longTerm, isEmpty);
      expect(recent, isEmpty);
    });

    test('битый JSON — не падает, оба слоя пустые', () {
      final (longTerm, recent) = decodeCentroids('не json{');
      expect(longTerm, isEmpty);
      expect(recent, isEmpty);
    });

    test('разбирает base64 long_term/recent', () {
      final v = _vecBytes([1, 0]);
      final json = jsonEncode({
        'long_term': [base64Encode(v)],
        'recent': [base64Encode(v)],
      });
      final (longTerm, recent) = decodeCentroids(json);
      expect(longTerm, hasLength(1));
      expect(recent, hasLength(1));
      expect(longTerm.first[0], closeTo(1.0, 1e-6));
    });
  });

  group('weightedShuffleByTaste', () {
    test('нет векторов/центров — всё равно вернёт все id (равномерная перетасовка)', () {
      final result = weightedShuffleByTaste(
        ids: ['a', 'b', 'c'],
        vecs: const {},
        artists: {'a': 'A', 'b': 'B', 'c': 'C'},
        centroidsLongTerm: const [],
        centroidsRecent: const [],
        rng: Random(1),
      );
      expect(result.toSet(), {'a', 'b', 'c'});
    });

    test('явный вкус — трек рядом с центром чаще оказывается раньше', () {
      final centroid = _vec([1, 0]);
      final close = _vec([0.95, 0.05]);
      final far = _vec([0, 1]);
      var closeFirstCount = 0;
      const trials = 200;
      for (var seed = 0; seed < trials; seed++) {
        final result = weightedShuffleByTaste(
          ids: ['close', 'far'],
          vecs: {'close': close, 'far': far},
          artists: {'close': 'A', 'far': 'B'},
          centroidsLongTerm: [centroid],
          centroidsRecent: const [],
          rng: Random(seed),
        );
        if (result.first == 'close') closeFirstCount++;
      }
      // Не строгий порядок (это всё ещё «перетасовка»), но заметный перекос.
      expect(closeFirstCount, greaterThan(trials * 0.7));
    });

    test('не больше 2 подряд одного исполнителя (соотношение 1:1, выполнимо при любом порядке)', () {
      // При случайном (взвешенном) порядке единственный «запасной» другой
      // исполнитель может достаться слишком рано и не хватить на хвост
      // (в отличие от orderOffline выше, где порядок задан score, а не
      // случайностью) — поэтому тут баланс 1:1, не 3:1.
      final vecs = {
        'a1': _vec([1, 0]), 'a2': _vec([1, 0]), 'a3': _vec([1, 0]),
        'b1': _vec([1, 0]), 'b2': _vec([1, 0]), 'b3': _vec([1, 0]),
      };
      final artists = {'a1': 'A', 'a2': 'A', 'a3': 'A', 'b1': 'B', 'b2': 'B', 'b3': 'B'};
      final result = weightedShuffleByTaste(
        ids: vecs.keys.toList(),
        vecs: vecs,
        artists: artists,
        centroidsLongTerm: const [],
        centroidsRecent: const [],
        rng: Random(2),
      );
      var run = 0;
      String? last;
      for (final id in result) {
        final artist = artists[id];
        if (artist == last) {
          run++;
        } else {
          run = 1;
          last = artist;
        }
        expect(run, lessThanOrEqualTo(2), reason: 'result=$result');
      }
    });
  });
}

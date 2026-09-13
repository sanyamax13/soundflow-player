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
}

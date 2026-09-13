import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/player/player_controller.dart';

NowPlaying _t(String id) => NowPlaying(id: id, title: id, artist: id, path: '/tmp/$id');

void main() {
  group('shufflePinned', () {
    test('трек с startIndex остаётся первым', () {
      final tracks = [_t('a'), _t('b'), _t('c'), _t('d')];
      final out = shufflePinned(tracks, 2, Random(1));
      expect(out.first.id, 'c');
    });

    test('остальные треки — та же компания, без потерь и дублей', () {
      final tracks = [_t('a'), _t('b'), _t('c'), _t('d'), _t('e')];
      final out = shufflePinned(tracks, 0, Random(42));
      expect(out.map((t) => t.id).toSet(), tracks.map((t) => t.id).toSet());
      expect(out.length, tracks.length);
    });

    test('одиночный список — просто он же', () {
      final tracks = [_t('solo')];
      final out = shufflePinned(tracks, 0, Random(7));
      expect(out.map((t) => t.id), ['solo']);
    });

    test('startIndex за границей — обрезается (clamp)', () {
      final tracks = [_t('a'), _t('b')];
      final out = shufflePinned(tracks, 99, Random(1));
      expect(out.first.id, 'b');
      expect(out.length, 2);
    });
  });
}

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

  group('newTracksToAppend (пункт 4 — новые скачки в Поток без рестарта)', () {
    test('в очереди уже есть часть — добавляются только новые', () {
      final queue = [_t('a'), _t('b')];
      final all = [_t('a'), _t('b'), _t('c'), _t('d')];
      final out = newTracksToAppend(queue, all, Random(1));
      expect(out.map((t) => t.id).toSet(), {'c', 'd'});
      expect(out.length, 2);
    });

    test('ничего нового — пустой список', () {
      final queue = [_t('a'), _t('b')];
      final out = newTracksToAppend(queue, [_t('a'), _t('b')], Random(1));
      expect(out, isEmpty);
    });
  });

  group('withoutArtistAfter (пункт 6 — скрыть исполнителя чистит очередь)', () {
    NowPlaying ta(String id, String artist) =>
        NowPlaying(id: id, title: id, artist: artist, path: '/tmp/$id');

    test('убирает только ещё не сыгранные треки этого исполнителя', () {
      final queue = [
        ta('a', 'X'), // сыгранный/текущий (afterIndex = 0)
        ta('b', 'Y'),
        ta('c', 'X'), // ещё не сыгранный, тот же исполнитель — убрать
        ta('d', 'Z'),
      ];
      final out = withoutArtistAfter(queue, 0, 'X');
      expect(out.map((t) => t.id), ['a', 'b', 'd']);
    });

    test('нет совпадений после текущего индекса — очередь не меняется', () {
      final queue = [ta('a', 'X'), ta('b', 'Y')];
      final out = withoutArtistAfter(queue, 0, 'Z');
      expect(out.map((t) => t.id), ['a', 'b']);
    });
  });
}

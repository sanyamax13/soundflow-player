import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/features/my_music/artist_grouping.dart';

DownloadedTrack _t(String id, String artist, String title) => DownloadedTrack(
      id: id,
      title: title,
      artist: artist,
      path: '/tmp/$id',
      bytes: 1,
      addedAt: 1,
    );

void main() {
  group('primaryArtist', () {
    test('обрезает feat / запятую / прочих приглашённых', () {
      expect(primaryArtist('9 грамм, Artizio'), '9 грамм');
      expect(primaryArtist('9 Грамм feat. Miyagi, Эндшпиль'), '9 Грамм');
      expect(primaryArtist('Armin Van Buuren Ft. Mr Probz'), 'Armin Van Buuren');
      expect(primaryArtist('Alan Walker/K-391/Julie Bergan'), 'Alan Walker');
      expect(primaryArtist('Sia; Sean Paul'), 'Sia');
      expect(primaryArtist('David Guetta'), 'David Guetta');
    });

    test('не режет имя с запятой перед артиклем', () {
      expect(primaryArtist('Tyler, The Creator'), 'Tyler, The Creator');
    });
  });

  group('artistKey — склейка вариантов', () {
    test('регистр и «ё» не различаются', () {
      expect(artistKey('9 грамм'), artistKey('9 Грамм'));
      expect(artistKey('THE WEEKND'), artistKey('The Weeknd'));
    });
  });

  group('isBrokenName', () {
    test('кракозябры ловятся', () {
      expect(isBrokenName('???? ????????, ??????? ???????'), isTrue);
      expect(isBrokenName('????? (BTS_'), isTrue);
    });
    test('нормальные имена — нет', () {
      expect(isBrokenName('9 грамм'), isFalse);
      expect(isBrokenName('AC/DC'), isFalse);
      expect(isBrokenName('P!nk'), isFalse);
      expect(isBrokenName('will.i.am'), isFalse);
    });
  });

  group('groupArtists', () {
    test('пять написаний «9 грамм» → одна папка', () {
      final (:folders, :broken) = groupArtists([
        _t('a', '9 грамм', 'п1'),
        _t('b', '9 Грамм', 'п2'),
        _t('c', '9 Грамм feat. Miyagi, Эндшпиль', 'п3'),
        _t('d', '9 грамм, Artizio', 'п4'),
        _t('e', '9 грамм, Lo Ali', 'п5'),
      ]);
      expect(broken, isEmpty);
      expect(folders, hasLength(1));
      expect(folders.single.count, 5);
      expect(folders.single.display, '9 грамм'); // строчный вариант, не ВЕРХНИЙ
    });

    test('битые имена уходят в broken, не в папки', () {
      final (:folders, :broken) = groupArtists([
        _t('a', 'Баста', 'Урбан'),
        _t('x', '???? ????????', '??????'),
      ]);
      expect(folders, hasLength(1));
      expect(broken.map((t) => t.id), ['x']);
    });

    test('папки отсортированы по имени', () {
      final folders = groupArtists([
        _t('a', 'Zivert', 'z'),
        _t('b', 'ABBA', 'a'),
        _t('c', 'Баста', 'b'),
      ]).folders;
      expect(folders.map((f) => f.display), ['ABBA', 'Zivert', 'Баста']);
    });
  });

  group('алфавит: латиница → кириллица → «#»', () {
    test('порядок папок и буквы разделов', () {
      final folders = groupArtists([
        _t('1', '50 Cent', 'a'),
        _t('2', 'Земляне', 'b'),
        _t('3', 'Beatles', 'c'),
        _t('4', 'Ёлка', 'd'),
        _t('5', 'Éluard', 'e'),
        _t('6', "'N Sync", 'f'),
        _t('7', 'Ая', 'g'),
        _t('8', '2 Unlimited', 'h'),
      ]).folders;
      expect(folders.map((f) => f.display),
          ['Beatles', 'Éluard', "'N Sync", 'Ая', 'Ёлка', 'Земляне', '2 Unlimited', '50 Cent']);
      expect(folders.map((f) => f.letter), ['B', 'E', 'N', 'А', 'Е', 'З', '#', '#']);
    });

    test('foldName: регистр, «ё», надстрочные знаки', () {
      expect(foldName('Motörhead'), 'motorhead');
      expect(foldName('ЁЛКА'), 'елка');
      expect(foldName('Édith Piaf'), 'edith piaf');
    });

    test('sectionLetter: кавычки и знаки в начале не мешают, без букв — «#»', () {
      expect(sectionLetter('"Weird Al" Yankovic'), 'W');
      expect(sectionLetter('...And You Will Know Us'), 'A');
      expect(sectionLetter('???'), '#');
      expect(sectionLetter('東京事変'), '#');
    });
  });
}

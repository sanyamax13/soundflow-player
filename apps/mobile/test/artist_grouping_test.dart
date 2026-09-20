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

  group('порядок в именах (Alex 20.09.2026, пункт 5)', () {
    test('номер трека с нулём впереди отрезается', () {
      expect(primaryArtist('01 Vengaboys'), 'Vengaboys');
      expect(primaryArtist('09. Steps'), 'Steps');
      expect(primaryArtist('2 Unlimited'), '2 Unlimited'); // без нуля — настоящее имя
      expect(primaryArtist('50 Cent'), '50 Cent');
    });

    test('«25/17», «AC/DC» — одно имя, а «Jay-Z/Linkin Park» — два', () {
      expect(primaryArtist('25/17'), '25/17');
      expect(primaryArtist('AC/DC'), 'AC/DC');
      expect(primaryArtist('Au/Ra'), 'Au/Ra');
      expect(primaryArtist('Jay-Z/Linkin Park'), 'Jay-Z');
      expect(primaryArtist('Jay-Z / Linkin Park'), 'Jay-Z');
      expect(primaryArtist('Alan Walker/K-391/Julie Bergan'), 'Alan Walker');
    });

    test('разные написания одного имени — одна папка', () {
      final folders = groupArtists([
        _t('1', 'A-Teens', 'a'),
        _t('2', 'A-Teens', 'b'),
        _t('3', 'A Teens', 'c'),
        _t('4', "A'Teens", 'd'),
        _t('5', 'Dj Bobo', 'e'),
        _t('6', 'DJ Bobo', 'f'),
        _t('7', 'Mr. President', 'g'),
        _t('8', 'Mr. President', 'g2'),
        _t('8b', 'Mr.President', 'h'),
        _t('9', 'E-Rotic', 'i'),
        _t('10', 'E Rotic', 'j'),
        _t('11', 'Snap', 'k'),
        _t('12', 'Snap!', 'l'),
        _t('13', 'DAB', 'm'),
        _t('14', 'Dab', 'n'),
      ]).folders;
      expect(folders.map((f) => (f.display, f.count)),
          [('A-Teens', 4), ('Dab', 2), ('Dj Bobo', 2), ('E-Rotic', 2), ('Mr. President', 3), ('Snap', 2)]);
    });

    test('совсем короткие имена со знаками не склеиваем: «B.O.B» и «Bob» — разные', () {
      final folders = groupArtists([_t('1', 'B.O.B', 'a'), _t('2', 'Bob', 'b')]).folders;
      expect(folders, hasLength(2));
    });

    test('«15 Robbie Williams» и «01 Vengaboys» сливаются с чистым двойником', () {
      final folders = groupArtists([
        _t('1', 'Robbie Williams', 'a'),
        _t('2', 'Robbie Williams', 'b'),
        _t('3', '15 Robbie Williams', 'c'),
        _t('4', 'Vengaboys', 'd'),
        _t('5', '01 Vengaboys', 'e'),
      ]).folders;
      expect(folders.map((f) => (f.display, f.count)), [('Robbie Williams', 3), ('Vengaboys', 2)]);
    });

    test('число в начале без двойника — настоящее имя, папка остаётся', () {
      final folders = groupArtists([
        _t('1', '2 Unlimited', 'a'),
        _t('2', '50 Cent', 'b'),
        _t('3', '3 Doors Down', 'c'),
        _t('4', '5 Seconds Of Summer', 'd'),
        _t('5', '5 Seconds of Summer', 'e'),
      ]).folders;
      expect(folders.map((f) => (f.display, f.count)),
          [('2 Unlimited', 1), ('3 Doors Down', 1), ('5 Seconds Of Summer', 2), ('50 Cent', 1)]);
    });
  });
}

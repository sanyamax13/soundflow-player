// Одноразовый рендер 5 вариантов экрана «Моя музыка» в PNG — чтобы Alex
// посмотрел их глазами до реализации. Не проверяет логику: golden-файлы тут
// это просто картинки. Запуск:
//   flutter test --update-goldens test/mymusic_mockups_test.dart
// Картинки лягут в test/goldens/mymusic_*.png
//
// Виджеты — настоящие (ListView, GridView, лаймовый SegmentedButton, тема
// Afisha, шрифт Oswald), данные — выдуманные ниже.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';

class _T {
  const _T(this.title, this.artist, this.mb, {this.fav = false});
  final String title;
  final String artist;
  final double mb;
  final bool fav;
}

const _tracks = <_T>[
  _T('Through The Years', 'Kenny Rogers', 10.9, fav: true),
  _T("I Can't Unlove You", 'Kenny Rogers', 7.9),
  _T('Buy Me A Rose', 'Kenny Rogers', 8.6),
  _T('Crazy', 'Kenny Rogers', 8.6),
  _T('Islands In The Stream', 'Kenny Rogers', 9.6, fav: true),
  _T('The Gambler', 'Kenny Rogers', 8.2),
  _T('Coward Of The County', 'Kenny Rogers', 8.9),
  _T('Jolene', 'Dolly Parton', 6.7, fav: true),
  _T('9 to 5', 'Dolly Parton', 7.1),
  _T('I Will Always Love You', 'Dolly Parton', 8.0),
  _T('Coat Of Many Colors', 'Dolly Parton', 6.2),
  _T('Dancing Queen', 'ABBA', 9.4, fav: true),
  _T('Mamma Mia', 'ABBA', 8.1),
  _T('The Winner Takes It All', 'ABBA', 10.2),
  _T('SOS', 'ABBA', 7.6),
  _T('Bohemian Rhapsody', 'Queen', 12.4, fav: true),
  _T('Somebody To Love', 'Queen', 10.8),
  _T("Don't Stop Me Now", 'Queen', 8.7),
  _T('Fields Of Gold', 'Sting', 9.1),
  _T('Englishman In New York', 'Sting', 9.8),
  _T('Shape Of My Heart', 'Sting', 8.3),
  _T('Go Your Own Way', 'Fleetwood Mac', 9.9),
  _T('Dreams', 'Fleetwood Mac', 8.4, fav: true),
  _T('The Chain', 'Fleetwood Mac', 10.1),
];

Color _artColor(String a) {
  final h = a.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0xffffff);
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.35, 0.30).toColor();
}

Widget _cover(String artist, double size, {double radius = 6}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _artColor(artist),
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.music_note, size: size * 0.42, color: Colors.white24),
    );

// заливка обложкой на всё доступное место (для сетки)
Widget _coverFill(String artist, {double radius = 8}) => DecoratedBox(
      decoration: BoxDecoration(
        color: _artColor(artist),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: const Center(
        child: Icon(Icons.music_note, size: 30, color: Colors.white24),
      ),
    );

// ─────────────────────────────────────────────────────────────────────────────
// 1. СТЕНА — плотный список в одну строчку, буквенная полоса справа, сортировка
// ─────────────────────────────────────────────────────────────────────────────
class MockWall extends StatelessWidget {
  const MockWall({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Моя музыка'), actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
          child: Row(children: [
            const Expanded(
              child: Text('4972 песни · 34.4 ГБ',
                  style: TextStyle(color: Afisha.inkDim, fontSize: 13)),
            ),
            _sortChip('Свежие', false),
            _sortChip('Исполнитель', true),
            _sortChip('Название', false),
          ]),
        ),
        const Divider(height: 1, color: Afisha.line),
        Expanded(
          child: Stack(children: [
            ListView(
              padding: const EdgeInsets.only(right: 22),
              children: [
                for (final t in [..._tracks, ..._tracks])
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Row(children: [
                      Expanded(
                        child: RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            style: const TextStyle(
                                fontFamily: Afisha.fontFamily,
                                fontSize: 15,
                                color: Afisha.ink),
                            children: [
                              TextSpan(text: t.title),
                              TextSpan(
                                  text: '   ${t.artist}',
                                  style: const TextStyle(
                                      color: Afisha.inkDim, fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                      if (t.fav)
                        const Icon(Icons.favorite,
                            size: 13, color: Afisha.lime),
                    ]),
                  ),
              ],
            ),
            Positioned(
              right: 2,
              top: 6,
              bottom: 6,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final c in 'ABCDFGKQST'.split(''))
                    Text(c,
                        style: TextStyle(
                            color: c == 'K' ? Afisha.lime : Afisha.inkDim,
                            fontSize: 11,
                            fontWeight: c == 'K'
                                ? FontWeight.w700
                                : FontWeight.w400)),
                ],
              ),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: const _MiniPlayer(),
    );
  }

  Widget _sortChip(String s, bool on) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Afisha.lime : Afisha.surfaceHi,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(s,
            style: TextStyle(
                fontSize: 12,
                color: on ? Colors.black : Afisha.inkDim,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. ПОЛКА — список исполнителей со счётчиком, переключатель сверху
// ─────────────────────────────────────────────────────────────────────────────
class MockShelf extends StatelessWidget {
  const MockShelf({super.key});
  @override
  Widget build(BuildContext context) {
    final byArtist = <String, int>{};
    for (final t in _tracks) {
      byArtist[t.artist] = (byArtist[t.artist] ?? 0) + 1;
    }
    // раздуем счётчики, чтобы выглядело как настоящая библиотека
    final artists = byArtist.entries
        .map((e) => MapEntry(e.key, e.value * 8 + e.key.length))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Scaffold(
      appBar: AppBar(title: const Text('Моя музыка'), actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: [
            const Text('312 исполнителей',
                style: TextStyle(color: Afisha.inkDim, fontSize: 13)),
            const Spacer(),
            _seg('Исполнители', true),
            _seg('Все песни', false),
          ]),
        ),
        const Divider(height: 1, color: Afisha.line),
        Expanded(
          child: ListView(
            children: [
              for (final a in [...artists, ...artists, ...artists])
                Column(children: [
                  ListTile(
                    leading: _cover(a.key, 44, radius: 22),
                    title: Text(a.key,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${a.value} песен',
                        style: const TextStyle(
                            color: Afisha.inkDim, fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Afisha.inkDim),
                  ),
                  const Divider(height: 1, color: Afisha.line),
                ]),
            ],
          ),
        ),
      ]),
      bottomNavigationBar: const _MiniPlayer(),
    );
  }

  Widget _seg(String s, bool on) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? Afisha.lime : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? Afisha.lime : Afisha.line),
        ),
        child: Text(s,
            style: TextStyle(
                fontSize: 12,
                color: on ? Colors.black : Afisha.inkDim,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. СТРОКА — поиск сверху, под ним короткие полки
// ─────────────────────────────────────────────────────────────────────────────
class MockSearchFirst extends StatelessWidget {
  const MockSearchFirst({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Моя музыка')),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Afisha.surfaceHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.search, color: Afisha.inkDim),
              SizedBox(width: 10),
              Text('Найти в моей музыке',
                  style: TextStyle(color: Afisha.inkDim, fontSize: 15)),
            ]),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('НЕДАВНО ДОБАВЛЕНО',
              style: TextStyle(
                  color: Afisha.inkDim, fontSize: 12, letterSpacing: 1)),
        ),
        SizedBox(
          height: 150,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final t in _tracks.take(8))
                Container(
                  width: 108,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _cover(t.artist, 108, radius: 8),
                        const SizedBox(height: 6),
                        Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                        Text(t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Afisha.inkDim, fontSize: 11)),
                      ]),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Text('ИЗБРАННОЕ',
              style: TextStyle(
                  color: Afisha.inkDim, fontSize: 12, letterSpacing: 1)),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final t in _tracks.where((t) => t.fav))
                ListTile(
                  dense: true,
                  leading: _cover(t.artist, 40),
                  title: Text(t.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist,
                      style: const TextStyle(
                          color: Afisha.inkDim, fontSize: 12)),
                ),
            ],
          ),
        ),
      ]),
      bottomNavigationBar: const _MiniPlayer(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. ВИТРИНА — сетка обложек по исполнителю
// ─────────────────────────────────────────────────────────────────────────────
class MockGrid extends StatelessWidget {
  const MockGrid({super.key});
  @override
  Widget build(BuildContext context) {
    final artists = <String>{for (final t in _tracks) t.artist}.toList();
    final all = [...artists, ...artists, ...artists, ...artists];
    return Scaffold(
      appBar: AppBar(title: const Text('Моя музыка'), actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: [
            const Text('312 исполнителей',
                style: TextStyle(color: Afisha.inkDim, fontSize: 13)),
            const Spacer(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: Afisha.line),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(children: [
                Text('Исполнитель',
                    style: TextStyle(color: Afisha.ink, fontSize: 12)),
                Icon(Icons.arrow_drop_down, color: Afisha.inkDim, size: 18),
              ]),
            ),
          ]),
        ),
        const Divider(height: 1, color: Afisha.line),
        Expanded(
          child: GridView.count(
            crossAxisCount: 3,
            padding: const EdgeInsets.all(12),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
            children: [
              for (var i = 0; i < all.length; i++)
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _coverFill(all[i])),
                  const SizedBox(height: 5),
                  Text(all[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                  Text('${(all[i].length * 7) % 40 + 5} песен',
                      style: const TextStyle(
                          color: Afisha.inkDim, fontSize: 10)),
                ]),
            ],
          ),
        ),
      ]),
      bottomNavigationBar: const _MiniPlayer(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. САМО РАЗЛОЖИТСЯ — стопка умных полок
// ─────────────────────────────────────────────────────────────────────────────
class MockSmart extends StatelessWidget {
  const MockSmart({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Моя музыка')),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Afisha.surfaceHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.search, color: Afisha.inkDim, size: 20),
              SizedBox(width: 10),
              Text('Найти песню',
                  style: TextStyle(color: Afisha.inkDim, fontSize: 14)),
            ]),
          ),
        ),
        _shelf('НЕДАВНО ДОБАВЛЕНО', _tracks.skip(2).take(6)),
        _shelf('СЛУШАЛ НА ЭТОЙ НЕДЕЛЕ', _tracks.skip(10).take(6)),
        _shelf('ДАВНО НЕ ИГРАЛ', _tracks.skip(5).take(6)),
        _shelf('ПОХОЖЕ НА ЛЮБИМОЕ', _tracks.where((t) => !t.fav).take(6)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(children: [
            const Icon(Icons.cleaning_services_outlined,
                size: 16, color: Afisha.inkDim),
            const SizedBox(width: 8),
            const Text('Кандидаты на удаление',
                style: TextStyle(color: Afisha.ink, fontSize: 14)),
            const Spacer(),
            const Text('47', style: TextStyle(color: Afisha.inkDim)),
            const Icon(Icons.chevron_right, color: Afisha.inkDim),
          ]),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Padding(
            padding: EdgeInsets.only(bottom: 20),
            child: Text('Вся музыка  →',
                style: TextStyle(color: Afisha.lime, fontSize: 14)),
          ),
        ),
      ]),
      bottomNavigationBar: const _MiniPlayer(),
    );
  }

  Widget _shelf(String title, Iterable<_T> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(children: [
              Text(title,
                  style: const TextStyle(
                      color: Afisha.inkDim, fontSize: 12, letterSpacing: 1)),
              const Spacer(),
              const Text('все',
                  style: TextStyle(color: Afisha.inkDim, fontSize: 12)),
            ]),
          ),
          SizedBox(
            height: 132,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final t in items)
                  Container(
                    width: 96,
                    margin: const EdgeInsets.only(right: 10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _cover(t.artist, 96, radius: 8),
                          const SizedBox(height: 5),
                          Text(t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11)),
                        ]),
                  ),
              ],
            ),
          ),
        ],
      );
}

// общий мини-плеер снизу — как в приложении
class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();
  @override
  Widget build(BuildContext context) => Container(
        height: 60,
        color: Afisha.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          _cover('Tap N P', 40),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('I Am A River', maxLines: 1),
                  Text('Tap N P',
                      style: TextStyle(color: Afisha.inkDim, fontSize: 12)),
                ]),
          ),
          const Icon(Icons.play_arrow, color: Afisha.lime),
          const SizedBox(width: 16),
          const Icon(Icons.skip_next, color: Afisha.ink),
        ]),
      );
}

Future<void> _shot(WidgetTester tester, Widget child, String name) async {
  await tester.binding.setSurfaceSize(const Size(400, 860));
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Afisha.theme(),
    home: MediaQuery(
      data: const MediaQueryData(size: Size(400, 860)),
      child: child,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await expectLater(
      find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    final oswald = File('assets/fonts/Oswald.ttf').readAsBytesSync();
    await (FontLoader('Oswald')
          ..addFont(Future.value(ByteData.view(oswald.buffer))))
        .load();

    // Иконки Material — их шрифт в тестах сам не грузится, выходили квадраты.
    for (final p in [
      r'E:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
      r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    ]) {
      final f = File(p);
      if (f.existsSync()) {
        final b = f.readAsBytesSync();
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(ByteData.view(b.buffer))))
            .load();
        break;
      }
    }
  });

  testWidgets('1 wall', (t) => _shot(t, const MockWall(), 'mymusic_1_wall'));
  testWidgets('2 shelf', (t) => _shot(t, const MockShelf(), 'mymusic_2_shelf'));
  testWidgets('3 search', (t) => _shot(t, const MockSearchFirst(), 'mymusic_3_search'));
  testWidgets('4 grid', (t) => _shot(t, const MockGrid(), 'mymusic_4_grid'));
  testWidgets('5 smart', (t) => _shot(t, const MockSmart(), 'mymusic_5_smart'));
}

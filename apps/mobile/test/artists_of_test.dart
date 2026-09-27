import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/features/my_music/artist_grouping.dart';

// 27.09.2026: выбор «кого слушать дальше» по исполнителям песни.
void main() {
  test('artistsOf — все исполнители строки по отдельности', () {
    expect(artistsOf('ILLENIUM feat. Tom Grennan & Alna'), ['ILLENIUM', 'Tom Grennan', 'Alna']);
    expect(artistsOf('Illenium; Teddy Swims'), ['Illenium', 'Teddy Swims']);
    expect(artistsOf('Нюша'), ['Нюша']);
    expect(artistsOf('Tyler, The Creator'), ['Tyler, The Creator']);
  });
  test('artistPartKey — регистр и точки не важны', () {
    expect(artistPartKey('ILLENIUM'), artistPartKey('Illenium'));
    expect(artistPartKey('Tom Grennan'), artistPartKey('TOM GRENNAN'));
  });
  test('groupArtists: «Noah & Erik Elias» — в папку Noah, «Simon & Garfunkel» — своя', () {
    DownloadedTrack t(String id, String a) => DownloadedTrack(id: id, title: id, artist: a, path: '/tmp/$id', bytes: 1, addedAt: 1);
    final g = groupArtists([t('1', 'Noah'), t('2', 'Noah & Erik Elias'), t('3', 'Simon & Garfunkel')]);
    expect(g.folders.map((f) => '${f.display}:${f.count}').toList(), ['Noah:2', 'Simon & Garfunkel:1']);
  });
}

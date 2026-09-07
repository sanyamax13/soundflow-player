import '../../data/db.dart';

/// Собирает разные написания одного исполнителя в одну «папку» для «Моей
/// музыки» (Alex TG 18687–18694, 07.09.2026):
///   «9 грамм», «9 Грамм», «9 грамм, Artizio», «9 Грамм feat. Miyagi»  →  «9 грамм».
/// Только показ — файлы и теги в базе не трогаем. Внутри папки у каждой песни
/// по-прежнему видно полное написание, так что совместки не теряются.

/// Разделители «главный — приглашённые». Запятую НЕ режем, если сразу за ней
/// артикль («Tyler, The Creator», «Earth, Wind…» так в одно имя и остаются).
final RegExp _sep = RegExp(
  r'\s*(?:'
  r',(?!\s*(?:the|los|las|die|el|le)\b)'
  r'|;|/|\\'
  r'|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b'
  r'|\bprod\.?\b|\bvs\.?\b|\bпри участии\b'
  r')',
  caseSensitive: false,
);

final RegExp _trimEnds = RegExp(r'^[\s\-–—.]+|[\s\-–—.]+$');
final RegExp _spaces = RegExp(r'\s+');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _lower = RegExp(r'\p{Ll}', unicode: true);
final RegExp _upper = RegExp(r'\p{Lu}', unicode: true);

/// Точечные правки битых тегов по id — там, где правильное имя нельзя вычислить
/// из строки, но известно (Alex TG 18693: «переименуй эту песню»). Применяются
/// один раз при обновлении списка; на сервере правится отдельно.
const Map<String, ({String artist, String title})> kTagFixes = {
  // «????? (BTS_» → это BTS, название «Come Back Home» и так читается.
  't_31e18358faf95fc4': (artist: 'BTS', title: 'Come Back Home'),
};

/// id песен, у которых сломано всё — имя, название, альбом. Чинить нечего,
/// восстановить неоткуда → тихо убираем при обновлении списка
/// (Alex TG 18691: «если не читаемо то удаляй»).
const Set<String> kDropBrokenIds = {
  't_cde2425083e92797',
};

/// Главный исполнитель из строки тега: всё до первого разделителя.
String primaryArtist(String raw) {
  final a = raw.trim();
  if (a.isEmpty) return '';
  final head = a.split(_sep).first.replaceAll(_trimEnds, '');
  return head.isEmpty ? a : head;
}

/// Ключ склейки: главный исполнитель без учёта регистра и лишних пробелов.
String artistKey(String raw) =>
    primaryArtist(raw).toLowerCase().replaceAll('ё', 'е').replaceAll(_spaces, ' ');

/// Имя-кракозябра: строка начинается с «??» либо знаков вопроса не меньше, чем букв.
bool isBrokenName(String s) {
  final t = s.trim();
  if (t.startsWith('??')) return true;
  final q = '?'.allMatches(t).length;
  if (q == 0) return false;
  final letters = _letter.allMatches(t).length;
  return letters == 0 || q >= letters;
}

/// 0 — Смешанный Регистр (лучший для показа), 1 — нижний, 2 — ВЕРХНИЙ.
int _casingScore(String s) {
  final low = _lower.hasMatch(s);
  final up = _upper.hasMatch(s);
  if (low && up) return 0;
  if (low) return 1;
  return 2;
}

/// Одна «папка» исполнителя — все его песни во всех написаниях.
class ArtistFolder {
  ArtistFolder(this.key, this.display, this.tracks);
  final String key;
  final String display;
  final List<DownloadedTrack> tracks;
  int get count => tracks.length;
}

/// Разложить скачанное по папкам исполнителей + отдельно вернуть песни с
/// нечитаемым именем (для секции «Имя не читается»).
({List<ArtistFolder> folders, List<DownloadedTrack> broken}) groupArtists(
    Iterable<DownloadedTrack> items) {
  final byKey = <String, List<DownloadedTrack>>{};
  final broken = <DownloadedTrack>[];

  for (final t in items) {
    if (isBrokenName(t.artist)) {
      broken.add(t);
      continue;
    }
    byKey.putIfAbsent(artistKey(t.artist), () => <DownloadedTrack>[]).add(t);
  }

  final folders = [
    for (final e in byKey.entries) ArtistFolder(e.key, _pickDisplay(e.value), e.value),
  ]..sort((a, b) => a.display.toLowerCase().compareTo(b.display.toLowerCase()));

  return (folders: folders, broken: broken);
}

/// Имя папки: самый частый вариант «главного исполнителя»; при равенстве —
/// с лучшим регистром («David Guetta», не «DAVID GUETTA») и покороче.
String _pickDisplay(List<DownloadedTrack> tracks) {
  final freq = <String, int>{};
  for (final t in tracks) {
    final p = primaryArtist(t.artist);
    freq[p] = (freq[p] ?? 0) + 1;
  }
  if (freq.isEmpty) return '';
  final ranked = freq.entries.toList()
    ..sort((a, b) {
      if (a.value != b.value) return b.value.compareTo(a.value);
      final ca = _casingScore(a.key), cb = _casingScore(b.key);
      if (ca != cb) return ca.compareTo(cb);
      return a.key.length.compareTo(b.key.length);
    });
  return ranked.first.key;
}

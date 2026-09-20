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

/// Основные надстрочные знаки → базовая буква: первый символ строки — буква,
/// остальные — её варианты.
const List<String> _accentGroups = [
  'aàáâãäåāăą', 'cçćč', 'dďđ', 'eèéêëēėęě', 'gğ', 'iìíîïīįı', 'lł', 'nñńň',
  'oòóôõöøōő', 'rř', 'sśšş', 'tť', 'uùúûüūůűų', 'yýÿ', 'zźżž',
];
final Map<int, String> _accentMap = {
  for (final g in _accentGroups)
    for (final r in g.runes.skip(1)) r: g[0],
};

/// Имя для сравнения, поиска и сортировки: нижний регистр, «ё» = «е», без
/// надстрочных знаков («Motörhead» → «motorhead», «Édith» → «edith»).
String foldName(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    if (r == 0x451) {
      b.write('е');
    } else {
      b.write(_accentMap[r] ?? String.fromCharCode(r));
    }
  }
  return b.toString();
}

final RegExp _leadJunk = RegExp(r'^[^\p{L}\p{N}]+', unicode: true);

/// Ключ сортировки: свёрнутое имя без кавычек, скобок и знаков в начале
/// («'N Sync» встаёт на N, «"Weird Al" Yankovic» — на W).
String _sortName(String display) {
  final f = foldName(display.trim());
  final s = f.replaceFirst(_leadJunk, '');
  return s.isEmpty ? f : s;
}

/// Буква раздела в алфавитном списке: латиница A–Z, кириллица А–Я, всё прочее
/// (цифры, значки, иероглифы) — «#».
String sectionLetter(String display) {
  final s = _sortName(display);
  if (s.isEmpty) return '#';
  final c = s.runes.first;
  if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c).toUpperCase();
  if (c >= 0x430 && c <= 0x4ff) return String.fromCharCode(c).toUpperCase();
  return '#';
}

/// Порядок разделов: сначала латиница, потом кириллица, «#» — в самом конце.
int sectionRank(String letter) {
  if (letter == '#') return 2;
  return letter.runes.first < 0x80 ? 0 : 1;
}

/// Одна «папка» исполнителя — все его песни во всех написаниях.
class ArtistFolder {
  ArtistFolder(this.key, this.display, this.tracks);
  final String key;
  final String display;
  final List<DownloadedTrack> tracks;
  int get count => tracks.length;

  /// Буква раздела, ключ сортировки и свёрнутое имя (для поиска) — считаются один раз.
  late final String letter = sectionLetter(display);
  late final String sortName = _sortName(display);
  late final String folded = foldName(display);
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

  // Алфавит: латиница, затем кириллица, затем «#» (цифры и значки) — как в
  // списке с полоской букв справа (Alex 20.09.2026, вид «Б»).
  final folders = [
    for (final e in byKey.entries) ArtistFolder(e.key, _pickDisplay(e.value), e.value),
  ]..sort((a, b) {
      final ra = sectionRank(a.letter), rb = sectionRank(b.letter);
      if (ra != rb) return ra.compareTo(rb);
      final c = a.sortName.compareTo(b.sortName);
      return c != 0 ? c : a.display.compareTo(b.display);
    });

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

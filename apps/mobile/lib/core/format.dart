// Мелкие «человеческие» форматтеры для экранов: числа, размеры, склонения.

/// 7543 → «7 543» (неразрывный пробел: число не рвётся на две строки).
String fmtInt(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// Размер по-русски: 85 МБ, 6,1 ГБ, 48 ГБ (десятые — только пока число мало).
String fmtBytes(int bytes) {
  const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
  if (bytes >= gb) {
    final v = bytes / gb;
    return '${(v >= 10 ? v.round().toString() : v.toStringAsFixed(1)).replaceAll('.', ',')} ГБ';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} МБ';
  if (bytes >= kb) return '${(bytes / kb).round()} КБ';
  return '$bytes Б';
}

/// Склонение по числу: 1 песня, 2 песни, 5 песен, 21 песня, 11 песен.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return few;
  return many;
}

String songWord(int n) => plural(n, 'песня', 'песни', 'песен');

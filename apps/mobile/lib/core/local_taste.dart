import 'dart:math' as math;
import 'dart:typed_data';

/// Офлайн-версия OrderRadio (apps/server/internal/localdb/radio.go) — без
/// сети, только среди уже скачанных треков. Без слоя session и без штрафов
/// за нелюбимых артистов/недавние скипы (для них нужна серверная история,
/// которой на телефоне нет) — но с правилом «не больше 2 подряд одного
/// исполнителя» (artist уже есть в downloaded_tracks, чисто локальные
/// данные). Формула — как sc := sim + 0.15*aff в radio.go, aff — блендед
/// 0.60*long+0.25*recent (без session, см.
/// docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md §4.5).

/// BLOB (little-endian float32) → Float32List. Проверяет длину (кратна 4);
/// НЕ делает Float32List.view напрямую — sqflite может вернуть Uint8List с
/// ненулевым offsetInBytes, на котором `.view()` падает при невыровненном
/// смещении, поэтому читаем через ByteData.getFloat32 в цикле.
Float32List? bytesToVec(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final n = bytes.length ~/ 4;
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

double _cosine(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  double dot = 0, na = 0, nb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

double _maxAffinity(List<Float32List> centroids, Float32List v) {
  if (centroids.isEmpty || v.isEmpty) return 0;
  var best = 0.0;
  for (final c in centroids) {
    final s = _cosine(c, v);
    if (s > best) best = s;
  }
  return best;
}

/// Порядок кандидатов: похожесть на seed + лёгкая добавка вкуса (60% долгий
/// + 25% недавний, без session), затем перестановка под правило «не больше
/// 2 подряд одного исполнителя» (тот же merge-цикл, что в radio.go, без
/// far-очереди антипузыря — она требует серверной статистики, которой нет
/// офлайн).
List<String> orderOffline({
  required Float32List seedVec,
  required Map<String, Float32List> candidateVecs,
  required Map<String, String> candidateArtists,
  required List<Float32List> centroidsLongTerm,
  required List<Float32List> centroidsRecent,
}) {
  final scored = <MapEntry<String, double>>[];
  for (final entry in candidateVecs.entries) {
    final v = entry.value;
    final sim = _cosine(seedVec, v);
    final affLong = _maxAffinity(centroidsLongTerm, v);
    final affRecent = _maxAffinity(centroidsRecent, v);
    final aff = 0.60 * affLong + 0.25 * affRecent;
    final sc = sim + 0.15 * aff;
    scored.add(MapEntry(entry.key, sc));
  }
  scored.sort((a, b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  });

  final pool = [for (final e in scored) e.key];
  final ordered = <String>[];
  String? lastArtist;
  var run = 0;
  while (pool.isNotEmpty) {
    var pick = 0;
    if (run >= 2) {
      final alt = pool.indexWhere((id) => candidateArtists[id] != lastArtist);
      if (alt != -1) pick = alt;
    }
    final id = pool.removeAt(pick);
    ordered.add(id);
    final artist = candidateArtists[id];
    if (artist == lastArtist) {
      run++;
    } else {
      lastArtist = artist;
      run = 1;
    }
  }
  return ordered;
}

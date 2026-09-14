import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Как считать тяжёлые офлайн-сравнения (см. `orderOffline` ниже,
/// вызывается из player_view.dart _offlineRadioFallback) — по умолчанию в
/// отдельном изоляте (`Isolate.run`), не на UI-потоке: на большой
/// библиотеке (тысячи кандидатов × центры вкуса) синхронный счёт на
/// главном изоляте подвешивал интерфейс на секунды, кнопка «не отвечала»,
/// звук заикался (Alex TG 14.09.2026). Виджет-тесты (`flutter test`)
/// зависают на настоящем `Isolate.run` НАВСЕГДА (проверено отдельным
/// пробным тестом — `Isolate.run(() => 1 + 1)` не завершается за 30 сек,
/// это ограничение самого тестового раннера, не баг в счёте) — поэтому
/// тесты подменяют этот раннер на прямой синхронный вызов (см.
/// player_radio_offline_test.dart) — не помечено `@visibleForTesting`,
/// чтобы не тянуть Flutter-зависимость в этот иначе чисто-Dart файл.
// ignore: prefer_function_declarations_over_variables
Future<T> Function<T>(T Function() body) offlineComputeRunner =
    <T>(body) => Isolate.run(body);

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

/// «Не больше 2 подряд одного исполнителя» — общий проход по уже
/// отсортированному пулу id, тот же merge-приём, что в radio.go (Go-версия
/// не делится кодом с Dart, но приём один и тот же, вынесен один раз здесь
/// для двух функций ниже).
List<String> _limitConsecutiveArtist(List<String> orderedByScore, Map<String, String> artists) {
  final pool = [...orderedByScore];
  final ordered = <String>[];
  String? lastArtist;
  var run = 0;
  while (pool.isNotEmpty) {
    var pick = 0;
    if (run >= 2) {
      final alt = pool.indexWhere((id) => artists[id] != lastArtist);
      if (alt != -1) pick = alt;
    }
    final id = pool.removeAt(pick);
    ordered.add(id);
    final artist = artists[id];
    if (artist == lastArtist) {
      run++;
    } else {
      lastArtist = artist;
      run = 1;
    }
  }
  return ordered;
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
  return _limitConsecutiveArtist([for (final e in scored) e.key], candidateArtists);
}

/// `orderOffline`, но разбор BLOB→Float32List (см. `bytesToVec`) — тоже
/// ВНУТРИ этой функции, не до неё. Раньше вызывающий код (player_view.dart
/// _offlineRadioFallback) разбирал тысячи BLOB'ов сам, ДО того, как отдать
/// счёт в изолят (`offlineComputeRunner`) — разбор байтов на тысячи
/// кандидатов (~2048 float каждый) сам по себе тяжёлый синхронный цикл,
/// оставался на UI-потоке и тормозил, хотя сам `orderOffline` уже считался
/// в фоне (Alex TG 14.09.2026: «обновил и всё равно задержка есть»). Теперь
/// весь тяжёлый счёт — разбор И ранжирование — за одним вызовом
/// `offlineComputeRunner`, целиком в фоновом изоляте.
List<String> orderOfflineFromBlobs({
  required Float32List seedVec,
  required Map<String, Uint8List> candidateBlobs,
  required Map<String, String> candidateArtists,
  required List<Float32List> centroidsLongTerm,
  required List<Float32List> centroidsRecent,
}) {
  final candidateVecs = <String, Float32List>{};
  for (final entry in candidateBlobs.entries) {
    final v = bytesToVec(entry.value);
    if (v != null) candidateVecs[entry.key] = v;
  }
  if (candidateVecs.length < 2) return const [];
  return orderOffline(
    seedVec: seedVec,
    candidateVecs: candidateVecs,
    candidateArtists: candidateArtists,
    centroidsLongTerm: centroidsLongTerm,
    centroidsRecent: centroidsRecent,
  );
}

/// Разобрать сохранённые центры вкуса (kv `taste_centroids`, JSON строкой,
/// пишет сервер — см. `cmd/soundflow/taste.go`) на списки векторов
/// long_term и recent. Нет записи ещё/битый JSON — оба слоя пустые (тот же
/// эффект, что «вкуса ещё нет», не крэш) — раньше это разбиралось инлайном
/// в player_view.dart _offlineRadioFallback без try/catch; вынесено сюда,
/// чтобы «Поток» (ниже) не дублировал тот же разбор второй раз.
(List<Float32List>, List<Float32List>) decodeCentroids(String? json) {
  if (json == null) return (const [], const []);
  try {
    final data = jsonDecode(json) as Map<String, dynamic>;
    Float32List? decode(String b64) => bytesToVec(base64Decode(b64));
    final longTerm = [
      for (final b in (data['long_term'] as List? ?? const [])) ?decode('$b'),
    ];
    final recent = [
      for (final b in (data['recent'] as List? ?? const [])) ?decode('$b'),
    ];
    return (longTerm, recent);
  } catch (_) {
    return (const [], const []);
  }
}

/// Взвешенная перетасовка «Потока» под вкус (Alex TG 14.09.2026: доделать
/// урезанный пункт 6 Опус-ревью — раньше учитывались только скрытые
/// исполнители, не сам вкус). Не строгая сортировка по affinity — тогда
/// каждый раз сверху были бы одни и те же фавориты, скучно — а взвешенная
/// выборка без повторов (Efraimidis–Spirakis): каждому треку ключ
/// rand()^(1/(aff+eps)), сортировка по убыванию ключа. Выше вкус — выше
/// шанс оказаться раньше, но не гарантия. Нет вкуса/отпечатков ещё — веса
/// у всех одинаковые, при равных весах приём математически вырождается в
/// обычную равномерную перетасовку — отдельный код на этот случай не нужен.
List<String> weightedShuffleByTaste({
  required List<String> ids,
  required Map<String, Float32List> vecs,
  required Map<String, String> artists,
  required List<Float32List> centroidsLongTerm,
  required List<Float32List> centroidsRecent,
  math.Random? rng,
}) {
  final r = rng ?? math.Random();
  const eps = 0.05;
  final keyed = <MapEntry<String, double>>[];
  for (final id in ids) {
    final v = vecs[id];
    var aff = 0.0;
    if (v != null) {
      final affLong = _maxAffinity(centroidsLongTerm, v);
      final affRecent = _maxAffinity(centroidsRecent, v);
      aff = 0.60 * affLong + 0.25 * affRecent;
    }
    final weight = aff + eps;
    final u = r.nextDouble().clamp(1e-9, 1.0);
    keyed.add(MapEntry(id, math.pow(u, 1 / weight).toDouble()));
  }
  keyed.sort((a, b) => b.value.compareTo(a.value));
  return _limitConsecutiveArtist([for (final e in keyed) e.key], artists);
}

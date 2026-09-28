import 'package:flutter/foundation.dart';

import '../../data/db.dart';

/// Вид плеера (Alex TG 22574 + голосовое 28.09.2026: «как смена управления»). Переключается в Профиле
/// одной строкой «Вид плеера». Вид меняет сразу и полосу, и что делает смахивание обложки.
enum SeekSkin {
  /// «Оценка»: пляшущий эквалайзер; обложку влево — удалить, вправо — лайк; кнопки-сердечка нет
  /// (дублировала бы смахивание).
  equalizer('Оценка'),

  /// «Листание»: стеклянная полоса (блик в темп песни); обложку влево — следующая, вправо —
  /// предыдущая; у названия — сердечко и урна.
  glass('Листание');

  const SeekSkin(this.label);
  final String label;
}

const _kSeekSkin = 'seek_skin';

/// Текущий вид — полоса слушает его и перерисовывается сразу.
final seekSkin = ValueNotifier<SeekSkin>(SeekSkin.equalizer);

Future<void> loadSeekSkin(Db db) async {
  final v = await db.kvGet(_kSeekSkin);
  seekSkin.value = SeekSkin.values.firstWhere((s) => s.name == v, orElse: () => SeekSkin.equalizer);
}

/// Следующий вид по кругу (их два — одно нажатие меняет, без меню).
Future<void> toggleSeekSkin(Db db) async {
  final next = SeekSkin.values[(seekSkin.value.index + 1) % SeekSkin.values.length];
  seekSkin.value = next;
  await db.kvSet(_kSeekSkin, next.name);
}

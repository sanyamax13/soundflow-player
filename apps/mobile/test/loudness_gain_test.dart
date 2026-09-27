import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/player/player_controller.dart';

// Выравнивание громкости (26.09.2026): цель −12 LUFS, приглушаем до −12 дБ, поднимаем до +6 дБ.
void main() {
  test('поправка громкости по LUFS', () {
    expect(PlayerController.loudnessGainDb(null), 0);
    expect(PlayerController.loudnessGainDb(0), 0, reason: '0 — сервер не знает');
    expect(PlayerController.loudnessGainDb(-8), -4, reason: 'громкая — тише');
    expect(PlayerController.loudnessGainDb(-16), 4, reason: 'тихая — громче');
    expect(PlayerController.loudnessGainDb(-40), 6, reason: 'поднимаем не больше 6 дБ');
    expect(PlayerController.loudnessGainDb(5), -12, reason: 'приглушаем не больше 12 дБ');
  });
}

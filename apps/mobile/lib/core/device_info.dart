import 'package:flutter/services.dart';

/// Модель телефона и тип связи — для окна «Устройства» на компьютере
/// (Alex TG 18917: «чтобы определялся именно какой телефон, а не просто
/// андроид, и как подключён — по Wi-Fi или по кабелю»).
///
/// Данные берёт нативный код в MainActivity.kt (канал `soundflow/device`),
/// без сторонних пакетов. Не Android или канал не ответил — отдаём
/// разумные заглушки, ничего не падает.
class DeviceInfo {
  const DeviceInfo({required this.model, required this.transport});

  /// Например «Samsung SM-S911B» или «Redmi Note 12». «Android», если не узнали.
  final String model;

  /// wifi | ethernet | mobile | vpn | '' (не узнали).
  final String transport;

  static const _ch = MethodChannel('soundflow/device');

  /// Спросить систему заново. Дёшево — зовём при каждой синхронизации, чтобы
  /// тип связи был свежим (переключился с Wi-Fi на кабель — сразу видно).
  static Future<DeviceInfo> read() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('info');
      final model = '${m?['model'] ?? ''}'.trim();
      return DeviceInfo(
        model: model.isEmpty ? 'Android' : model,
        transport: '${m?['transport'] ?? ''}'.trim(),
      );
    } catch (_) {
      return const DeviceInfo(model: 'Android', transport: '');
    }
  }
}

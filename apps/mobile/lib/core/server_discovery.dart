import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Порты, на которых может стоять программа SoundFlow — 8090 обычный по
/// умолчанию, 8091 запасной (был занят другой программой на компе Alex,
/// 13.09.2026). Список короткий и фиксированный осознанно (YAGNI) — полный
/// перебор портов не нужен, известны ровно эти два варианта.
const _discoveryPorts = [8090, 8091];

/// Найти в сети адрес компьютера с открытой программой SoundFlow — без
/// ручного ввода (Alex TG 13.09.2026: «пусть скан делает и находит
/// сервер-программу»). Сначала проверяет `127.0.0.1` (адрес компа при
/// USB-кабеле — программа сама поднимает `adb reverse`, см.
/// `cmd/soundflow/usbtunnel.go`), затем перебирает подсеть Wi-Fi
/// (`192.168.х.1..254`). Возвращает `http://host:port` первого ответившего
/// именно SoundFlow (поле `service` в `/v1/health` — отличает от случайно
/// занятого кем-то ещё того же порта, как было с TorrServer 13.09.2026),
/// либо `null`, если никто не ответил.
/// [scanSubnet] — false пропускает перебор Wi-Fi-подсети (только
/// `127.0.0.1`, для USB) — используется при тихом запуске приложения,
/// чтобы не задерживать старт на десяток секунд; кнопка «Найти сервер
/// самому» всегда сканирует полностью.
/// [candidatesOverride]/[dioOverride] — только для тестов (не гонять реальную
/// сеть/254 адреса в юнит-тестах); в проде вызывать без параметров.
Future<String?> discoverServer({
  bool scanSubnet = true,
  List<String>? candidatesOverride,
  Dio? dioOverride,
}) async {
  final candidates = candidatesOverride ?? await _buildCandidates(scanSubnet);
  final dio = dioOverride ?? Dio();
  return _probeAll(candidates, dio);
}

Future<List<String>> _buildCandidates(bool scanSubnet) async {
  final candidates = <String>[
    for (final port in _discoveryPorts) 'http://127.0.0.1:$port',
  ];
  if (!scanSubnet) return candidates;
  final prefix = await _localSubnetPrefix();
  if (prefix != null) {
    for (var i = 1; i <= 254; i++) {
      for (final port in _discoveryPorts) {
        candidates.add('http://$prefix.$i:$port');
      }
    }
  }
  return candidates;
}

/// Первые три числа собственного Wi-Fi-адреса телефона («192.168.1» из
/// «192.168.1.63») — предполагаем обычную домашнюю сеть /24, как везде в
/// проекте. Не нашли ни одного адреса (нет Wi-Fi) — `null`, сканировать
/// нечего.
Future<String?> _localSubnetPrefix() async {
  try {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length == 4) return '${parts[0]}.${parts[1]}.${parts[2]}';
      }
    }
  } catch (_) {
    // нет сети/permission — просто не сканируем подсеть
  }
  return null;
}

// Таймаут Dio (connectTimeout) на некоторых Android-телефонах не успевает
// оборвать зависшее ARP/TCP-подключение к несуществующему адресу подсети
// (обнаружено 13.09.2026 на реальном устройстве Alex — автопоиск не находил
// программу, хотя вручную адрес отвечал сразу). Поэтому дополнительно рубим
// снаружи через Future.timeout — это гарантирует потолок по времени
// независимо от того, что происходит внутри сокета.
const _perRequestTimeout = Duration(milliseconds: 700);
const _batchSize = 32;

Future<String?> _probeAll(List<String> urls, Dio dio) async {
  for (var i = 0; i < urls.length; i += _batchSize) {
    final end = i + _batchSize > urls.length ? urls.length : i + _batchSize;
    final batch = urls.sublist(i, end);
    final results = await Future.wait(batch.map((u) => _probeOne(dio, u)));
    for (final found in results) {
      if (found != null) return found;
    }
  }
  return null;
}

Future<String?> _probeOne(Dio dio, String url) async {
  try {
    final res = await dio
        .get<Map<String, dynamic>>('$url/v1/health')
        .timeout(_perRequestTimeout);
    if (res.statusCode == 200 && res.data?['service'] == 'soundflow') {
      return url;
    }
  } catch (_) {
    // не ответил / не тот сервис / истёк таймаут — обычный исход перебора
  }
  return null;
}

import 'dart:async';

import '../data/api.dart';
import '../data/db.dart';
import 'notice.dart';
import 'server_discovery.dart';

/// Ключ базы: последний адрес, который реально подтвердил себя рабочим (см. ServerUrlScreen).
const kLastGoodUrl = 'last_reachable_server_url';

/// Чем кончилось «Найти компьютер».
enum PairResult {
  /// Подключились и сохранили адрес (и адрес ВДС, если он у компьютера настроен).
  connected,

  /// В сети никто не ответил.
  notFound,

  /// Компьютер нашёлся, но на нём не открыто «Подключить телефон».
  notReady,

  /// Окно на компьютере закрылось, пока подключались.
  expired,
}

/// Найти компьютер в Wi-Fi и подключиться к нему — одно действие для экрана первого запуска
/// (ConnectScreen) и для «Найти сервер самому» в Профиле. Первое подключение — только с
/// согласия на компьютере: там должно быть открыто окно «Подключить телефон» (Alex TG 24.09.2026).
/// Старая программа без этой ручки — сохраняем молча, как раньше.
/// [name] получает имя компьютера для сообщения.
Future<PairResult> findAndPair(Api api, Db db, {void Function(String name)? name}) async {
  final found = await discoverServer().timeout(const Duration(seconds: 20), onTimeout: () => null);
  if (found == null) return PairResult.notFound;
  if (!await Api.ping(found)) return PairResult.notFound;
  final info = await Api.pairingCheck(found);
  if (info == null) {
    await persistServer(api, db, found);
    name?.call(found);
    return PairResult.connected;
  }
  if (!info.open) return PairResult.notReady;
  final confirm = await Api.pairingConfirm(found);
  if (!confirm.ok) return PairResult.expired;
  await persistServer(api, db, found);
  await _persistRelay(api, db, confirm.relayUrl, confirm.relayKey);
  name?.call(info.name.isEmpty ? found : info.name);
  return PairResult.connected;
}

/// Плашка с итогом «Найти компьютер».
void showPairResult(PairResult r, String name) {
  switch (r) {
    case PairResult.connected:
      Notice.show('Связь с компьютером установлена', subtitle: name, kind: NoticeKind.done);
    case PairResult.notFound:
      Notice.show('Компьютер не найден',
          subtitle: 'Телефон и компьютер должны быть в одной сети Wi-Fi, SoundFlow на компьютере — открыт',
          kind: NoticeKind.warn);
    case PairResult.notReady:
      Notice.show('Компьютер найден, но не готов',
          subtitle: 'На компьютере нажмите «Подключить телефон» и попробуйте снова', kind: NoticeKind.warn);
    case PairResult.expired:
      Notice.show('Не успели', subtitle: 'Окно на компьютере закрылось — попробуйте снова', kind: NoticeKind.warn);
  }
}

/// Сохранить адрес компьютера как текущий и как «последний рабочий».
Future<void> persistServer(Api api, Db db, String raw) async {
  api.setBaseUrl(raw);
  await db.kvSet('server_url', api.baseUrl);
  await db.kvSet(kLastGoodUrl, api.baseUrl);
}

/// Адрес и ключ связи через ВДС — компьютер отдаёт их при подтверждении подключения, если у него
/// это настроено. Раньше их только запоминали, а включали вручную в «Настройки → Удалённый
/// доступ»; с 28.09.2026 (своя копия плеера у другого человека) — включаем сразу: человек настроил
/// ВДС в мастере на компьютере ради этого. Не пришли — не трогаем, что уже сохранено.
Future<void> _persistRelay(Api api, Db db, String? relayUrl, String? relayKey) async {
  if (relayUrl == null || relayUrl.isEmpty || relayKey == null || relayKey.isEmpty) return;
  await db.kvSet('relay_url', relayUrl);
  await db.kvSet('relay_key', relayKey);
  await db.kvSet('relay_enabled', '1');
  final home = api.baseUrl;
  api.setRelayTransport(relayUrl, relayKey);
  api.setHomeUrl(home);
  unawaited(api.pickRoute().catchError((Object _) => false));
}

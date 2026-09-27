import 'dart:async';

import 'package:flutter/widgets.dart';

import 'downloads_repo.dart';
import 'sync_offer.dart';
import 'sync_repo.dart';

/// Сам отправляет накопленные события (лайки, удаления, что слушал) на
/// сервер, когда есть связь (Alex 06.09.2026 — раньше только руками кнопкой):
///  - через несколько секунд после запуска приложения;
///  - при возврате приложения на экран из фона;
///  - раз в несколько минут, пока приложение открыто;
///  - через несколько секунд после нового события (пачка лайков → один заход).
///
/// Связь отдельно не проверяем — просто пробуем отправить. Не вышло (сервер
/// не в домашней сети / молчит) — молча ждём следующего раза: события лежат
/// в очереди, дедуп по uuid не даёт задвоить.
///
/// План с компьютера (что скачать / что стереть) отсюда больше НЕ выполняется:
/// с 20.09.2026 телефон его только смотрит и предлагает ([SyncOffer.refresh]),
/// а качает и стирает по нажатию (Alex TG 20167: места на телефоне может не
/// хватить, решать ему).
class AutoSync with WidgetsBindingObserver {
  AutoSync(this._sync, this._downloads, [this._offer]);

  final SyncRepo _sync;
  final DownloadsRepo _downloads;
  final SyncOffer? _offer;

  static const _period = Duration(minutes: 3);
  static const _debounce = Duration(seconds: 5);
  static const _startupDelay = Duration(seconds: 4);

  Timer? _periodic;
  Timer? _debounced;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _sync.onEnqueued = _onEnqueued;
    _periodic = Timer.periodic(_period, (_) => _trySync());
    Timer(_startupDelay, _trySync);
  }

  void dispose() {
    _periodic?.cancel();
    _debounced?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sync.onEnqueued = null;
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _trySync();
  }

  void _onEnqueued() {
    _debounced?.cancel();
    _debounced = Timer(_debounce, _trySync);
  }

  Future<void> _trySync() async {
    // Пришёл домой / ушёл из дома — переключить дорогу к серверу (напрямую или через VDS).
    try {
      await _sync.api.pickRoute();
    } catch (_) {}
    try {
      // Раньше дёргали сервер, только когда pendingCount()>0 — из-за этого
      // запись устройства (когда/как на связи) на компе не обновлялась
      // просто от того, что телефон открыт и на связи (Alex TG 15.09.2026:
      // «телефон по вайфаю подключён, а в шапке программы не видно»).
      // sync() теперь сам решает внутри, слать ли реальные события или
      // просто «я живой» — вызываем всегда.
      // Только вес одним запросом: полная сводка (summary) читала все песни и
      // проверяла каждую обложку на диске — на 6000 песен это каждые 3 минуты
      // (и при каждом возврате в приложение) лишняя секунда работы.
      final bytes = (await _downloads.stats()).bytes;
      await _sync.sync(musicBytes: bytes);
    } catch (_) {
      // Нет связи с сервером — не страшно, события в очереди, попробуем позже.
    }
    // Старые лайки без файла (Alex TG 15.09.2026) — не событие, шлём
    // отдельно и каждый заход: дёшево (сервер просто обновляет отметку
    // времени), сеть недоступна — молча пропускаем, попробуем в другой раз.
    try {
      final favs = await _downloads.favoritesForReport();
      await _sync.reportFavorites(favs);
    } catch (_) {}
    // Что ждёт на компьютере (план из окна программы) — только смотрим и
    // предлагаем; связи нет — карточка сама скажет, попробуем в следующий раз.
    await _offer?.refresh();
    // Разовый возврат песен на компьютер (21.09.2026): фоном, ждать не нужно, все ошибки глотает сам.
    unawaited(_downloads.returnFilesToPc());
    // Точный список песен телефона для сверки с компьютером (21.09.2026): фоном, сам глотает ошибки.
    unawaited(_downloads.reportInventory());
  }
}

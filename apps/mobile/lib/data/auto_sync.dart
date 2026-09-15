import 'dart:async';

import 'package:flutter/widgets.dart';

import 'downloads_repo.dart';
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
/// в очереди, дедуп по uuid не даёт задвоить. Кнопка «Синхронизировать
/// сейчас» в профиле остаётся как была.
class AutoSync with WidgetsBindingObserver {
  AutoSync(this._sync, this._downloads);

  final SyncRepo _sync;
  final DownloadsRepo _downloads;

  static const _period = Duration(minutes: 3);
  static const _debounce = Duration(seconds: 5);
  static const _startupDelay = Duration(seconds: 4);

  Timer? _periodic;
  Timer? _debounced;
  bool _started = false;
  bool _applyingPlan = false;

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
    try {
      if (await _sync.pendingCount() > 0) {
        final bytes = (await _downloads.summary()).bytes;
        await _sync.sync(musicBytes: bytes);
      }
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
    // План ручной синхронизации (Alex собрал в окне на компе — кнопка,
    // галочки, «Далее»). Проверяем каждый заход, даже когда событий в
    // очереди нет: телефон «только принимает инфу» (Alex TG 19002).
    // Закачка плана может быть долгой — не пускаем два прохода разом.
    if (!_applyingPlan) {
      _applyingPlan = true;
      try {
        await _downloads.applyPendingPlan();
      } catch (_) {
        // Нет связи / план не забрали — подхватим в следующий раз.
      } finally {
        _applyingPlan = false;
      }
    }
  }
}

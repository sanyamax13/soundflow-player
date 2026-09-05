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
      if (await _sync.pendingCount() == 0) return;
      final bytes = (await _downloads.summary()).bytes;
      await _sync.sync(musicBytes: bytes);
    } catch (_) {
      // Нет связи с сервером — не страшно, события в очереди, попробуем позже.
    }
  }
}

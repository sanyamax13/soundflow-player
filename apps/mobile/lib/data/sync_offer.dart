import 'dart:async';

import 'package:flutter/material.dart';

import '../core/device_info.dart';
import '../core/format.dart';
import '../core/net_hint.dart';
import '../core/notice.dart';
import 'downloads_repo.dart';

/// «Что ждёт телефон на компьютере» — одно место вместо двух кнопок «Скачать
/// музыку» и «Синхронизировать сейчас» (Alex TG 20158, 20167: «я путаюсь, и в
/// итоге ничего не попадает на телефон»).
///
/// Как работает: компьютер сам решает, что положить на телефон (окно
/// программы: меню «Добавить на телефон», список с галочками; новые
/// скачанные песни программа кладёт туда сама) и складывает это в план.
/// Телефон план только СМОТРИТ ([refresh]) и предлагает: «На компьютере 12
/// новых песен (85 МБ) — скачать?». Пока Alex не нажмёт «Скачать»/«Стереть»
/// ([run]), ничего не качается и не стирается — места на телефоне может не
/// хватить, решать ему.
///
/// 26.09.2026 (разбор Gemini «плашки», Alex): новые песни качаются САМИ, когда
/// телефон дома в Wi-Fi ([autoDownload], переключатель в «Связи с домом»), без
/// плашки «Скачать?». Не хватает места — не качаем, красная карточка. Убранное на
/// компьютере само НЕ стирается — только кнопкой в карточке. Плашки-предложения с
/// кнопками сверху больше нет: кнопки наверху за рулём не достать.
class SyncOffer extends ChangeNotifier {
  SyncOffer(
    this._downloads, {
    Future<int?> Function()? freeSpace,
    Future<bool> Function()? atHome,
    this.autoDownload = true,
    this.onAutoChanged,
  })  : _freeSpace = freeSpace ?? DeviceInfo.freeSpaceBytes,
        _atHome = atHome ?? _defaultAtHome;

  final DownloadsRepo _downloads;
  final Future<int?> Function() _freeSpace;
  final Future<bool> Function() _atHome;

  /// Качать новое само, дома по Wi-Fi (по умолчанию включено).
  bool autoDownload;

  /// Сохранить переключатель (main.dart пишет в базу телефона).
  final void Function(bool)? onAutoChanged;

  void setAutoDownload(bool v) {
    autoDownload = v;
    onAutoChanged?.call(v);
    notifyListeners();
    if (v) unawaited(refresh());
  }

  static Future<bool> _defaultAtHome() async {
    final t = (await DeviceInfo.read()).transport;
    return t == 'wifi' || t == 'ethernet';
  }

  /// Запас свободного места, который не занимаем скачиванием: телефону нужно
  /// место и для своей работы.
  static const spaceReserve = 1024 * 1024 * 1024;

  PlanPreview preview = PlanPreview.empty;
  int? freeBytes;
  DateTime? checkedAt;

  /// Последняя попытка спросить компьютер не удалась (нет связи).
  bool lastCheckFailed = false;

  bool running = false;
  bool removingNow = false;
  int done = 0;
  int total = 0;
  String current = '';

  /// Сколько прогонов закончилось — экраны со списком песен по этому числу
  /// понимают, что пора перечитать список.
  int runs = 0;

  DownloadCancelToken? _token;
  bool _refreshing = false;

  /// Только для тестов и картинок: выставить состояние без обращения к серверу.
  @visibleForTesting
  void debugSet({
    PlanPreview? preview,
    int? freeBytes,
    bool? running,
    bool? removingNow,
    int? done,
    int? total,
    String? current,
    DateTime? checkedAt,
  }) {
    if (preview != null) this.preview = preview;
    if (freeBytes != null) this.freeBytes = freeBytes;
    if (running != null) this.running = running;
    if (removingNow != null) this.removingNow = removingNow;
    if (done != null) this.done = done;
    if (total != null) this.total = total;
    if (current != null) this.current = current;
    if (checkedAt != null) this.checkedAt = checkedAt;
    notifyListeners();
  }

  bool get hasOffer => !preview.isEmpty;

  bool get lowSpace =>
      preview.addBytes > 0 &&
      freeBytes != null &&
      freeBytes! < preview.addBytes + spaceReserve;

  String get addTitle =>
      'На компьютере ${fmtInt(preview.addCount)} '
      '${plural(preview.addCount, 'новая песня', 'новые песни', 'новых песен')} '
      '(${fmtBytes(preview.addBytes)})';

  String get addSubtitle {
    final f = freeBytes;
    if (f == null) return 'Скачать на телефон?';
    // Вместо окна «Мало места» — прямо на карточке, сколько не хватает (27.09.2026, разбор Gemini и Алисы).
    return lowSpace
        ? 'Не хватит места: нужно ещё ${fmtBytes(preview.addBytes + spaceReserve - f)}'
        : 'На телефоне свободно ${fmtBytes(f)}';
  }

  String get removeTitle =>
      'На компьютере убрали ${fmtInt(preview.removeCount)} '
      '${plural(preview.removeCount, 'песню', 'песни', 'песен')}';

  String get removeSubtitle => 'Стереть с телефона?';

  /// Спросить компьютер, что лежит в плане. Ничего не качает. [announce] —
  /// показать плашку-предложение (при заходе в приложение, см. AutoSync).
  Future<void> refresh({bool announce = true}) async {
    if (running || _refreshing) return;
    _refreshing = true;
    try {
      final p = await _downloads.previewPlan();
      final free = await _freeSpace();
      preview = p;
      freeBytes = free;
      checkedAt = DateTime.now();
      lastCheckFailed = false;
      notifyListeners();
      if (announce) await _maybeAutoRun();
    } catch (_) {
      lastCheckFailed = true;
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  /// Выполнить: [adds] — скачать, [removes] — стереть. Зовётся кнопками.
  Future<void> run({required bool adds, required bool removes, bool auto = false}) async {
    if (running) return;
    final token = DownloadCancelToken();
    _token = token;
    running = true;
    removingNow = !adds;
    done = 0;
    total = (adds ? preview.addCount : 0) + (removes ? preview.removeCount : 0);
    current = '';
    notifyListeners();
    try {
      final r = await _downloads.applyPendingPlan(
        adds: adds,
        removes: removes,
        cancelToken: token,
        onProgress: (d, t, title) {
          done = d;
          total = t;
          current = title;
          notifyListeners();
        },
      );
      _report(r, auto: auto);
    } catch (_) {
      if (!auto) showServerUnreachable(lead: 'Не получилось');
    } finally {
      running = false;
      _token = null;
      runs++;
      notifyListeners();
    }
    await refresh(announce: false);
  }

  /// «Стоп»: текущая песня докачается, следующая не начнётся.
  void cancel() => _token?.cancel();

  /// Сама качает новое, если: включено, есть что качать, места хватает и телефон
  /// дома (Wi-Fi, не удалённый доступ). Стирание — никогда само.
  Future<void> _maybeAutoRun() async {
    final p = preview;
    if (!autoDownload || running || p.addCount == 0 || lowSpace) return;
    if (!await _atHome()) return;
    await run(adds: true, removes: false, auto: true);
  }

  void _report(({int added, int removed, int failed, bool stopped}) r, {bool auto = false}) {
    // Наверху — только короткие плашки без кнопок (разбор Gemini 26.09.2026).
    if (auto) {
      if (r.added > 0) {
        Notice.show(
          'Скачано ${fmtInt(r.added)} '
          '${plural(r.added, 'новая песня', 'новые песни', 'новых песен')}',
          kind: NoticeKind.done,
          duration: const Duration(seconds: 3),
        );
      }
      return;
    }
    final parts = [
      if (r.added > 0) 'скачано ${r.added}',
      if (r.removed > 0) 'стёрто ${r.removed}',
    ];
    final did = parts.isEmpty
        ? null
        : '${parts.first[0].toUpperCase()}${parts.join(' · ').substring(1)}';
    if (r.stopped) {
      Notice.show('Остановлено', subtitle: did);
    } else if (r.failed > 0) {
      Notice.show(
        'Не всё получилось',
        subtitle: '${did == null ? '' : '$did. '}Не вышло: ${r.failed}',
        kind: NoticeKind.warn,
      );
    } else if (did == null) {
      Notice.show('Всё уже на месте', kind: NoticeKind.done, duration: const Duration(seconds: 3));
    } else {
      Notice.show('Готово', subtitle: did, kind: NoticeKind.done, duration: const Duration(seconds: 3));
    }
  }
}

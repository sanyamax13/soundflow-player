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
class SyncOffer extends ChangeNotifier {
  SyncOffer(this._downloads, {Future<int?> Function()? freeSpace})
    : _freeSpace = freeSpace ?? DeviceInfo.freeSpaceBytes;

  final DownloadsRepo _downloads;
  final Future<int?> Function() _freeSpace;

  /// Запас свободного места, который не занимаем скачиванием: телефону нужно
  /// место и для своей работы.
  static const spaceReserve = 1024 * 1024 * 1024;

  /// Не объявлять одно и то же чаще, чем раз в это время (если не менялось).
  static const _repeatAfter = Duration(minutes: 30);

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
  String? _announcedSig;
  DateTime? _announcedAt;
  String? _snoozedSig;

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
    return lowSpace
        ? 'Не хватит места: свободно ${fmtBytes(f)}'
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
      if (announce) _announce();
    } catch (_) {
      lastCheckFailed = true;
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  /// Выполнить: [adds] — скачать, [removes] — стереть. Зовётся кнопками.
  Future<void> run({required bool adds, required bool removes}) async {
    if (running) return;
    if (adds && preview.addCount > 0 && lowSpace && !await _confirmLowSpace()) {
      return;
    }
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
      _report(r);
    } catch (_) {
      showServerUnreachable(lead: 'Не получилось');
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

  void _report(({int added, int removed, int failed, bool stopped}) r) {
    final parts = [
      if (r.added > 0) 'скачано ${r.added}',
      if (r.removed > 0) 'стёрто ${r.removed}',
    ];
    final did = parts.isEmpty
        ? null
        : '${parts.first[0].toUpperCase()}${parts.join(' · ').substring(1)}';
    if (r.stopped) {
      Notice.show('Остановил', subtitle: did);
    } else if (r.failed > 0) {
      Notice.show(
        'Не всё получилось',
        subtitle:
            '${did == null ? '' : '$did. '}Не вышло: ${r.failed}. Нажми ещё раз',
        kind: NoticeKind.warn,
      );
    } else if (did == null) {
      Notice.show('Всё уже на месте', kind: NoticeKind.done);
    } else {
      Notice.show('Готово', subtitle: did, kind: NoticeKind.done);
    }
  }

  /// Плашка-предложение при заходе в приложение: «Скачать?» — да / не сейчас.
  /// Одно и то же не повторяем чаще раза в полчаса, а после «Не сейчас» — вообще
  /// пока предложение не изменится (карточка на экране остаётся).
  void _announce() {
    final p = preview;
    if (p.isEmpty || running) return;
    final sig = p.signature;
    if (sig == _snoozedSig) return;
    final now = DateTime.now();
    final at = _announcedAt;
    if (sig == _announcedSig &&
        at != null &&
        now.difference(at) < _repeatAfter) {
      return;
    }
    _announcedSig = sig;
    _announcedAt = now;

    final add = p.addCount > 0;
    final rem = p.removeCount > 0;
    final String title;
    final String sub;
    final String label;
    if (add && rem) {
      title = 'Есть новое на компьютере';
      sub =
          'Скачать ${fmtInt(p.addCount)} (${fmtBytes(p.addBytes)}) и стереть ${fmtInt(p.removeCount)}?';
      label = 'Скачать и стереть';
    } else if (add) {
      title = addTitle;
      sub = addSubtitle;
      label = 'Скачать';
    } else {
      title = removeTitle;
      sub = removeSubtitle;
      label = 'Стереть';
    }
    Notice.show(
      title,
      subtitle: sub,
      kind: lowSpace ? NoticeKind.warn : NoticeKind.info,
      duration: const Duration(seconds: 12),
      actions: [
        NoticeAction(label, () => run(adds: add, removes: rem)),
        NoticeAction('Не сейчас', () => _snoozedSig = sig, primary: false),
      ],
    );
  }

  Future<bool> _confirmLowSpace() async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return false;
    final go = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Мало места'),
        content: Text(
          'На телефоне свободно ${fmtBytes(freeBytes ?? 0)}, а нужно '
          '${fmtBytes(preview.addBytes)}. Скачивание может остановиться на '
          'середине. Всё равно начать?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Начать'),
          ),
        ],
      ),
    );
    return go == true;
  }
}

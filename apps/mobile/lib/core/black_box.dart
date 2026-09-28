import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// «Чёрный ящик» — подробный журнал всего, что происходит в приложении (Alex TG 21786,
/// 26.09.2026: «очень подробный, чтобы каждый клик и каждое дуновение ветра фиксировал»).
///
/// Пишется: каждое нажатие и смахивание (куда и по чему), переходы между экранами и
/// вкладками, прокрутка, всё про плеер (что играет, пауза, перемотка, ошибки, звонки,
/// отключение наушников/Bluetooth, кнопки магнитолы), каждый запрос к серверу (адрес,
/// ответ, время), сеть, батарея (заряд, зарядка, температура, экономия), память,
/// подтормаживания интерфейса, сворачивание/разворачивание, почему система в прошлый раз
/// закрыла приложение, все ошибки.
///
/// Как устроено, чтобы самому не есть батарею: события копятся в памяти и раз в 15 с
/// дописываются в файл дня (`blackbox/ГГГГ-ММ-ДД.jsonl`, одна строка JSON на событие).
/// Раз в 10 минут (и при сворачивании) новое сжатым куском уходит на домашний сервер
/// (`POST /v1/blackbox`); нет связи — остаётся на телефоне и уйдёт потом. На телефоне
/// хранится до 14 дней и не больше 150 МБ.
class BlackBox {
  BlackBox._();

  static final _buf = <String>[];
  static Directory? _dir;
  static int _seq = 0;
  static bool _started = false;
  static bool _live = false; // режим отладки: частая отправка логов разработчику (по согласию)
  static String? debugDevice; // id устройства для сборщика отладки на ВДС
  // Сборщик отладки на ВДС (collector.py). Токен общий — просто чтобы не спамили посторонние.
  static const _debugUrl = 'https://vdsmusic.ru/soundflow-debug';
  static const _debugToken = '4a7927601b06872e43750495d4ee6b1a';
  static bool _dbgUploading = false;

  /// Включить/выключить живую отладку. On — сразу отправить накопленное.
  static void setLive(bool on) {
    _live = on;
    log('debug_live', {'on': on});
    if (on) unawaited(flush().then((_) async { await uploadNow(); await _uploadDebug(); }));
  }

  static bool get live => _live;
  static bool _flushing = false;
  static bool _uploading = false;

  /// Номер запуска — все события одного запуска приложения с ним.
  static final String session =
      (DateTime.now().millisecondsSinceEpoch.toRadixString(36) + Random().nextInt(1 << 20).toRadixString(36));

  static Future<void> Function(List<int> gz)? _upload;

  static const _channel = MethodChannel('soundflow/device');
  static const _keepDays = 14;
  static const _maxBytes = 150 << 20;
  static const _maxUploadChunk = 4 << 20;

  /// Записать событие. [k] — вид («tap», «play», «http»…), [d] — подробности.
  static void log(String k, [Map<String, Object?>? d]) {
    try {
      final m = <String, Object?>{
        't': DateTime.now().toIso8601String(),
        'k': k,
        's': session,
        'n': _seq++,
        ...?d,
      };
      _buf.add(jsonEncode(m, toEncodable: (o) => o.toString()));
      if (_buf.length >= 400) unawaited(flush());
    } catch (_) {
      // Журнал никогда не должен ронять приложение.
    }
  }

  /// Дописать накопленное в файл дня.
  static Future<void> flush() async {
    if (_flushing || _buf.isEmpty) return;
    _flushing = true;
    try {
      final dir = _dir ??= await _openDir();
      final lines = List.of(_buf);
      _buf.clear();
      final byDay = <String, StringBuffer>{};
      for (final l in lines) {
        final day = l.length > 16 ? l.substring(6, 16) : _day(DateTime.now());
        (byDay[day] ??= StringBuffer()).writeln(l);
      }
      for (final e in byDay.entries) {
        await File('${dir.path}/${e.key}.jsonl').writeAsString(e.value.toString(), mode: FileMode.append, flush: true);
      }
    } catch (_) {
    } finally {
      _flushing = false;
    }
  }

  static String _day(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static Future<Directory> _openDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/blackbox');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// Запустить всё: таймеры, перехват нажатий, жизненный цикл, кадры. Зовётся один раз из main.
  /// [upload] — отправка сжатого куска на сервер (бросает исключение, если не вышло).
  static void start({required Future<void> Function(List<int> gz) upload}) {
    if (_started) return;
    _started = true;
    _upload = upload;
    Timer.periodic(const Duration(seconds: 15), (_) => unawaited(flush()));
    Timer.periodic(const Duration(minutes: 5), (_) => unawaited(_pulse()));
    Timer.periodic(const Duration(minutes: 10), (_) => unawaited(uploadNow()));
    // Режим отладки (Alex 28.09.2026): по согласию — частая отправка, чтобы разработчик видел «в моменте».
    Timer.periodic(const Duration(seconds: 6), (_) {
      if (_live) unawaited(flush().then((_) async { await uploadNow(); await _uploadDebug(); }));
    });
    Timer(const Duration(seconds: 20), () => unawaited(uploadNow()));
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    AppLifecycleListener(onStateChange: (s) {
      log('lifecycle', {'state': s.name});
      if (s == AppLifecycleState.paused || s == AppLifecycleState.detached) {
        unawaited(flush().then((_) => uploadNow()));
      }
    });
    unawaited(_startInfo());
  }

  static Future<void> _startInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('info');
      final ver = await _channel.invokeMethod<int>('appVersionCode');
      log('start', {'version': ver, 'os': Platform.operatingSystemVersion, ...?info});
    } catch (_) {
      log('start', {'os': Platform.operatingSystemVersion});
    }
    // Почему система закрыла приложение в прошлые разы (Android 11+): нехватка памяти,
    // сбой, «не отвечает», убито экономией батареи, смахнули из недавних и т.п.
    try {
      final exits = await _channel.invokeListMethod<Map<Object?, Object?>>('exitReasons');
      final dir = _dir ??= await _openDir();
      final seenF = File('${dir.path}/.exits_seen');
      final seen = seenF.existsSync() ? int.tryParse(seenF.readAsStringSync()) ?? 0 : 0;
      var newest = seen;
      for (final e in exits ?? const <Map<Object?, Object?>>[]) {
        final ts = (e['timestamp'] as num?)?.toInt() ?? 0;
        if (ts <= seen) continue;
        newest = max(newest, ts);
        log('exit_reason', {
          'when': DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String(),
          'reason': e['reason'],
          'status': e['status'],
          'importance': e['importance'],
          'pss_kb': e['pss'],
          'rss_kb': e['rss'],
          'desc': e['description'],
        });
      }
      if (newest > seen) seenF.writeAsStringSync('$newest');
    } catch (_) {}
    await _pulse();
  }

  // ---- Пульс раз в 5 минут: батарея, сеть, память, подтормаживания. ----

  static String? _lastTransport;
  static int _slowFrames = 0;
  static int _frames = 0;
  static int _worstFrameMs = 0;
  static DateTime _lastJankLog = DateTime(2000);

  /// Отправка журнала на общий сборщик отладки ВДС (только в режиме отладки). Свои смещения в
  /// .sentdbg, чтобы не дублировать. Ошибки глушим — отладка не должна мешать приложению.
  static Future<void> _uploadDebug() async {
    if (!_live || _dbgUploading || debugDevice == null) return;
    _dbgUploading = true;
    try {
      final dir = _dir ??= await _openDir();
      final offF = File('${dir.path}/.sentdbg');
      final sent = <String, int>{};
      if (offF.existsSync()) {
        try {
          (jsonDecode(offF.readAsStringSync()) as Map).forEach((k, v) => sent['$k'] = (v as num).toInt());
        } catch (_) {}
      }
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final len = f.lengthSync();
        var off = sent[name] ?? 0;
        while (off < len) {
          final raf = f.openSync();
          final List<int> bytes;
          try {
            raf.setPositionSync(off);
            bytes = raf.readSync(min(_maxUploadChunk, len - off));
          } finally {
            raf.closeSync();
          }
          final cut = bytes.lastIndexOf(10) + 1;
          if (cut <= 0) break;
          final ok = await _postDebug(gzip.encode(bytes.sublist(0, cut)));
          if (!ok) return; // нет связи — попробуем позже
          off += cut;
          sent[name] = off;
          offF.writeAsStringSync(jsonEncode(sent));
        }
      }
    } catch (_) {
    } finally {
      _dbgUploading = false;
    }
  }

  static Future<bool> _postDebug(List<int> gz) async {
    try {
      final cl = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await cl.postUrl(Uri.parse(_debugUrl));
      req.headers.set('X-Device', debugDevice ?? 'unknown');
      req.headers.set('X-Debug-Token', _debugToken);
      req.headers.set('Content-Encoding', 'gzip');
      req.headers.set('Content-Type', 'application/json');
      req.add(gz);
      final resp = await req.close();
      await resp.drain<void>();
      cl.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _pulse() async {
    final d = <String, Object?>{};
    try {
      final b = await _channel.invokeMapMethod<String, Object?>('battery');
      if (b != null) d.addAll(b);
    } catch (_) {}
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('info');
      final tr = info?['transport'] as String?;
      d['net'] = tr;
      if (tr != _lastTransport) {
        log('net_change', {'from': _lastTransport, 'to': tr});
        _lastTransport = tr;
      }
    } catch (_) {}
    d['rss_mb'] = (ProcessInfo.currentRss / (1 << 20)).round();
    d['frames'] = _frames;
    d['slow_frames'] = _slowFrames;
    d['worst_frame_ms'] = _worstFrameMs;
    _frames = 0;
    _slowFrames = 0;
    _worstFrameMs = 0;
    log('pulse', d);
  }

  static void _onFrames(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames++;
      final ms = t.totalSpan.inMilliseconds;
      if (ms > 34) {
        _slowFrames++;
        // Совсем долгий кадр (заметное «замирание») — отдельной строкой, но не чаще раза
        // в 5 с: остальные и так посчитаны в пульсе (slow_frames / worst_frame_ms).
        final now = DateTime.now();
        if (ms > 250 && now.difference(_lastJankLog) > const Duration(seconds: 5)) {
          _lastJankLog = now;
          log('jank', {'ms': ms, 'build_ms': t.buildDuration.inMilliseconds, 'raster_ms': t.rasterDuration.inMilliseconds});
        }
      }
      if (ms > _worstFrameMs) _worstFrameMs = ms;
    }
  }

  // ---- Нажатия и смахивания по всему приложению. ----

  static final _downs = <int, (Offset, DateTime)>{};

  static void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _downs[e.pointer] = (e.position, DateTime.now());
      return;
    }
    if (e is PointerCancelEvent) {
      _downs.remove(e.pointer);
      return;
    }
    if (e is! PointerUpEvent) return;
    final start = _downs.remove(e.pointer);
    if (start == null) return;
    final (p0, t0) = start;
    final delta = e.position - p0;
    final ms = DateTime.now().difference(t0).inMilliseconds;
    final String kind;
    if (delta.distance < 18) {
      kind = ms > 500 ? 'long_press' : 'tap';
    } else if (delta.dx.abs() > delta.dy.abs()) {
      kind = delta.dx > 0 ? 'swipe_right' : 'swipe_left';
    } else {
      kind = delta.dy > 0 ? 'swipe_down' : 'swipe_up';
    }
    log(kind, {
      'x': p0.dx.round(),
      'y': p0.dy.round(),
      if (kind != 'tap' && kind != 'long_press') 'dx': delta.dx.round(),
      if (kind != 'tap' && kind != 'long_press') 'dy': delta.dy.round(),
      'ms': ms,
      'on': _whatIsAt(p0, e.viewId),
    });
  }

  /// По чему попали пальцем: подписи и тексты под точкой нажатия (кнопка «Оставить»,
  /// строка «До рассвета», значок…), от самого глубокого к внешнему, до 4 штук.
  static String _whatIsAt(Offset pos, int viewId) {
    try {
      final result = HitTestResult();
      RendererBinding.instance.hitTestInView(result, pos, viewId);
      final out = <String>[];
      for (final entry in result.path) {
        final t = entry.target;
        String? s;
        if (t is RenderParagraph) {
          s = t.text.toPlainText();
          if (s.length == 1 && s.codeUnitAt(0) >= 0xE000) {
            s = 'icon:${s.codeUnitAt(0).toRadixString(16)}';
          }
        } else if (t is RenderSemanticsAnnotations) {
          final p = t.properties;
          s = p.label ?? p.tooltip ?? p.value;
        }
        if (s == null) continue;
        s = s.replaceAll('\n', ' ').trim();
        if (s.isEmpty || out.contains(s)) continue;
        out.add(s.length > 60 ? '${s.substring(0, 60)}…' : s);
        if (out.length >= 4) break;
      }
      return out.join(' | ');
    } catch (_) {
      return '';
    }
  }

  // ---- Отправка на сервер. ----

  /// Отправить всё новое, что ещё не ушло. Сколько уже ушло из каждого файла — в
  /// `.sent` (имя файла → байт), чтобы при обрыве не слать повторно.
  static Future<void> uploadNow() async {
    final up = _upload;
    if (up == null || _uploading) return;
    _uploading = true;
    try {
      await flush();
      final dir = _dir ??= await _openDir();
      final sentF = File('${dir.path}/.sent');
      final sent = <String, int>{};
      if (sentF.existsSync()) {
        try {
          (jsonDecode(sentF.readAsStringSync()) as Map).forEach((k, v) => sent['$k'] = (v as num).toInt());
        } catch (_) {}
      }
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final len = f.lengthSync();
        var off = sent[name] ?? 0;
        while (off < len) {
          final raf = f.openSync();
          final List<int> bytes;
          try {
            raf.setPositionSync(off);
            bytes = raf.readSync(min(_maxUploadChunk, len - off));
          } finally {
            raf.closeSync();
          }
          // Режем по последнему переводу строки, чтобы не отправлять полстроки.
          var cut = bytes.lastIndexOf(10) + 1;
          if (cut <= 0) break;
          await up(gzip.encode(bytes.sublist(0, cut)));
          off += cut;
          sent[name] = off;
          sentF.writeAsStringSync(jsonEncode(sent));
        }
      }
      _cleanup(dir, files, sent);
      sentF.writeAsStringSync(jsonEncode(sent));
    } catch (_) {
      // Нет связи с сервером — не беда, отправим в следующий раз.
    } finally {
      _uploading = false;
    }
  }

  static void _cleanup(Directory dir, List<File> files, Map<String, int> sent) {
    final cutoff = _day(DateTime.now().subtract(const Duration(days: _keepDays)));
    final today = _day(DateTime.now());
    var total = 0;
    for (final f in files.reversed) {
      final name = f.uri.pathSegments.last;
      final day = name.replaceAll('.jsonl', '');
      final len = f.existsSync() ? f.lengthSync() : 0;
      final fullySent = (sent[name] ?? 0) >= len;
      total += len;
      // Старые отправленные дни на телефоне не нужны; неотправленные — держим до 14 дней
      // или пока общий объём не превысит 150 МБ.
      if ((fullySent && day != today) || day.compareTo(cutoff) < 0 || total > _maxBytes) {
        try {
          f.deleteSync();
          sent.remove(name);
        } catch (_) {}
      }
    }
  }
}

/// Переходы между экранами (открыли / закрыли / заменили).
class BlackBoxNavObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? r) {
    if (r == null) return '';
    final n = r.settings.name;
    if (n != null && n.isNotEmpty) return n;
    return r.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      BlackBox.log('nav_push', {'route': _name(route), 'from': _name(previousRoute)});

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      BlackBox.log('nav_pop', {'route': _name(route), 'to': _name(previousRoute)});

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      BlackBox.log('nav_replace', {'route': _name(newRoute), 'old': _name(oldRoute)});
}

/// Прокрутка: куда долистали (одно событие на конец прокрутки, не на каждый кадр).
bool blackBoxScroll(ScrollEndNotification n) {
  final m = n.metrics;
  if (m.maxScrollExtent > 0) {
    BlackBox.log('scroll', {
      'axis': m.axis.name,
      'px': m.pixels.round(),
      'max': m.maxScrollExtent.round(),
    });
  }
  return false;
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Общий журнал событий приложения — не сбои (см. [CrashLog]/[PlayerIssueLog]),
/// а обычная работа: нажал радио — сколько реально прошло миллисекунд,
/// сколько кандидатов обработал, что скачивалось. Нужен, чтобы разбирать
/// проблемы по фактам С ТЕЛЕФОНА Alex, а не по пересказу словами — важно
/// именно потому, что замеры на компе (SSD/память сильно быстрее) не отражают
/// реальность на телефоне (Alex TG 14.09.2026: «ты должен как-то на моём
/// телефоне... какая реальность задержка идёт у меня, а не с компьютера»).
///
/// Храним только НЕДАВНЕЕ — по времени, не по числу строк (Alex TG
/// 14.09.2026: «поставь какой-то лимит, чтобы не было огромных списков...
/// на час либо на сколько-то ещё») — старше [_maxAge] обрезаем при каждой
/// записи.
class AppLog {
  AppLog._();

  static const _maxAge = Duration(hours: 3);
  static File? _file;

  static Future<File> _f() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    return _file = File('${dir.path}/app_log.txt');
  }

  /// Записать событие. [data] — произвольные пары ключ=значение в конец
  /// строки (elapsed_ms, count, id и т.п.) — просто текст, не JSON: этот файл
  /// читает человек (Alex или я), не парсер.
  static Future<void> event(String what, [Map<String, Object?>? data]) async {
    try {
      final line = StringBuffer()
        ..write(DateTime.now().toIso8601String())
        ..write(' ')
        ..write(what);
      data?.forEach((k, v) => line.write(' $k=$v'));

      final f = await _f();
      final existing = f.existsSync() ? await f.readAsString() : '';
      final cutoff = DateTime.now().subtract(_maxAge);
      final kept = existing.split('\n').where((l) {
        final sp = l.indexOf(' ');
        if (sp < 1) return false;
        final ts = DateTime.tryParse(l.substring(0, sp));
        return ts != null && ts.isAfter(cutoff);
      });
      await f.writeAsString('${[...kept, line.toString()].join('\n')}\n');
    } catch (_) {
      // Диагностика не должна ронять приложение.
    }
  }

  static Future<String?> read() async {
    try {
      final f = await _f();
      if (!f.existsSync()) return null;
      final s = (await f.readAsString()).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _f();
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static const _channel = MethodChannel('soundflow/device');

  /// Системное окно «Поделиться» — Alex сам выбирает Телеграм и отправляет
  /// текст журнала в наш чат (TG 14.09.2026: «я сам буду отправлять»), без
  /// отдельного транспорта на сервер.
  static Future<void> share(String text) => _channel.invokeMethod<void>('shareText', {'text': text});
}

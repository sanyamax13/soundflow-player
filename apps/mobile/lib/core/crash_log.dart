import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Ошибка загрузки/разбора КАРТИНКИ (обложка по сети без связи, битый файл) —
/// Flutter присылает её в общий обработчик с пометкой «image resource service».
/// Приложение от неё не падает, плитка просто остаётся без обложки, поэтому в
/// «чёрный ящик» она не пишется (Alex TG 20169: на мобильном интернете
/// «Последний сбой» показывал таймаут обложки с домашнего компьютера).
bool isHarmlessImageError(FlutterErrorDetails details) =>
    details.library == 'image resource service';

/// «Чёрный ящик»: последнее необработанное падение приложения пишется в файл,
/// чтобы потом показать его в Профиле и отправить на сервер. Без этого причина
/// вылета нигде не оставалась (Alex TG 19028 — «плеер вылетает, просто
/// закрывается, следа нет»). Храним только последнее падение — перезаписываем.
class CrashLog {
  CrashLog._();

  static File? _file;

  static Future<File> _f() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    return _file = File('${dir.path}/last_crash.txt');
  }

  /// Записать падение. [where] — грубая пометка, откуда пришло (flutter /
  /// platform / zone / player), помогает понять слой.
  static Future<void> write(Object error, StackTrace? stack, {String where = ''}) async {
    try {
      final f = await _f();
      final buf = StringBuffer()
        ..writeln(DateTime.now().toIso8601String())
        ..writeln(where.isEmpty ? 'слой: неизвестно' : 'слой: $where')
        ..writeln(error.toString());
      final st = stack?.toString() ?? '';
      if (st.isNotEmpty) {
        // Первые строки стека — обычно там и есть виновник; файл не раздуваем.
        final lines = st.split('\n');
        buf.writeln(lines.take(12).join('\n'));
      }
      await f.writeAsString(buf.toString());
    } catch (_) {
      // Не смогли записать — не усугубляем, приложение и так падает.
    }
  }

  /// Текст последнего падения (null — файла нет).
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
}

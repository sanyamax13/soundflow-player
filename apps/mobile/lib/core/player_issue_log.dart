import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'black_box.dart';

/// Тихий лог сбоев ВОСПРОИЗВЕДЕНИЯ (плеер пропустил битый/недоступный файл и
/// сам поехал дальше) — ОТДЕЛЬНО от [CrashLog] (core/crash_log.dart), который
/// только для настоящих падений приложения. До этого файла оба случая писали
/// в один last_crash.txt, и обычный пропуск песни показывался в Профиле как
/// пугающее «Приложение падало» с техническим стеком — Опус-ревью телефона
/// 14.09.2026, пункт 2. Храним только последний случай — перезаписываем, как
/// и CrashLog.
class PlayerIssueLog {
  PlayerIssueLog._();

  static File? _file;

  static Future<File> _f() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    return _file = File('${dir.path}/player_issues.txt');
  }

  static Future<void> write(Object error, StackTrace? stack, {String where = ''}) async {
    BlackBox.log('player_issue', {
      'where': where,
      'error': error.toString(),
      if (stack != null) 'stack': stack.toString().split('\n').take(15).join('\n'),
    });
    try {
      final f = await _f();
      final buf = StringBuffer()
        ..writeln(DateTime.now().toIso8601String())
        ..writeln(where.isEmpty ? 'слой: неизвестно' : 'слой: $where')
        ..writeln(error.toString());
      await f.writeAsString(buf.toString());
    } catch (_) {
      // Не смогли записать — не критично, это диагностика, а не сама ошибка.
    }
  }
}

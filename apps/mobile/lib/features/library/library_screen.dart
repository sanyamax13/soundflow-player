import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/device_info.dart';
import '../../core/net_hint.dart';
import '../../core/theme.dart';
import '../../data/downloads_repo.dart';

/// «Библиотека»: сколько уже скачано, кнопка «докачать ещё» — сервер сам
/// подбирает следующую порцию (избранное вперёд) под заданный объём,
/// телефон качает её по одному треку. Только по кнопке — фонового
/// автоскачивания нет, Alex сам решает, когда качать ещё.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

enum _BatchGB { gb10, gb20, gb50 }

extension on _BatchGB {
  int get bytes => switch (this) {
        _BatchGB.gb10 => 10 * 1024 * 1024 * 1024,
        _BatchGB.gb20 => 20 * 1024 * 1024 * 1024,
        _BatchGB.gb50 => 50 * 1024 * 1024 * 1024,
      };
  String get label => switch (this) {
        _BatchGB.gb10 => '10 ГБ',
        _BatchGB.gb20 => '20 ГБ',
        _BatchGB.gb50 => '50 ГБ',
      };
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int? _count;
  int? _bytes;
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  String _current = '';
  _BatchGB _batch = _BatchGB.gb10;
  DownloadCancelToken? _cancelToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_count == null) _load();
  }

  @override
  void dispose() {
    // Ушёл с экрана посреди скачивания — раньше порция продолжала качаться
    // фоном без возможности остановить (Опус-ревью телефона 14.09.2026,
    // пункт 7). Текущий трек докачается, следующий уже нет.
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref.read(downloadsProvider).summary();
    if (!mounted) return;
    setState(() {
      _count = s.count;
      _bytes = s.bytes;
    });
  }

  Future<void> _downloadMore() async {
    final messenger = ScaffoldMessenger.of(context);

    // Проверка места на телефоне ПЕРЕД стартом (пункт 7) — раньше порция
    // могла остановиться на середине без объяснений, если места не хватало.
    final free = await DeviceInfo.freeSpaceBytes();
    if (free != null && free < _batch.bytes) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Мало места'),
          content: Text(
              'На телефоне свободно только ${_fmtBytes(free)}, а порция — ${_batch.label}. '
              'Скачивание может остановиться на середине. Всё равно начать?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Начать')),
          ],
        ),
      );
      if (go != true) return;
    }
    if (!mounted) return;

    final downloads = ref.read(downloadsProvider);
    final token = DownloadCancelToken();
    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
      _current = '';
      _cancelToken = token;
    });
    try {
      final r = await downloads.downloadMore(
        budgetBytes: _batch.bytes,
        cancelToken: token,
        onProgress: (done, total, title) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _current = title;
          });
        },
      );
      final stopped = token.isCancelled;
      if (r.downloaded == 0 && r.failed == 0 && !stopped) {
        messenger.showSnackBar(const SnackBar(content: Text('Новых песен на сервере не осталось')));
      } else {
        final failedNote = r.failed > 0 ? ', не вышло — ${r.failed}' : '';
        final lead = stopped ? 'Остановлено. Скачано' : 'Докачано';
        messenger.showSnackBar(SnackBar(
          content: Text('$lead: ${r.downloaded}$failedNote (${_fmtBytes(r.bytes)})'),
        ));
      }
    } catch (_) {
      if (mounted) showServerUnreachableSnackBar(context, messenger);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelToken = null;
        });
      }
      await _load();
    }
  }

  void _stop() => _cancelToken?.cancel();

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ';
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(0)} МБ';
    return '$b Б';
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    final bytes = _bytes;
    return Scaffold(
      appBar: AppBar(title: const Text('Скачать музыку')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            count == null ? '…' : 'Скачано: $count песен, ${_fmtBytes(bytes ?? 0)}',
            style: const TextStyle(fontSize: 22, color: Afisha.ink),
          ),
          const SizedBox(height: 24),
          const Text('Порция за раз', style: TextStyle(color: Afisha.inkDim)),
          const SizedBox(height: 8),
          SegmentedButton<_BatchGB>(
            segments: _BatchGB.values
                .map((b) => ButtonSegment(value: b, label: Text(b.label)))
                .toList(),
            selected: {_batch},
            onSelectionChanged: _busy ? null : (s) => setState(() => _batch = s.first),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_busy || count == null) ? null : _downloadMore,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Докачать ещё ${_batch.label}'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _total == 0 ? 'Спрашиваю сервер…' : 'Скачано $_done из $_total',
                    style: const TextStyle(color: Afisha.inkDim),
                  ),
                ),
                TextButton(onPressed: _stop, child: const Text('Стоп')),
              ],
            ),
            if (_current.isNotEmpty)
              Text(_current, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Afisha.inkDim)),
          ],
          const SizedBox(height: 24),
          const Text(
            'Сервер сам выбирает, что качать дальше — сначала то, что было в '
            'избранном в старом плеере. Докачивать ещё — только по этой кнопке, '
            'само по себе ничего не скачивается.',
            style: TextStyle(color: Afisha.inkDim, height: 1.4),
          ),
        ],
      ),
    );
  }
}

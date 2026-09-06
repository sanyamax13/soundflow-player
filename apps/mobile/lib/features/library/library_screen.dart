import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';

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
  _BatchGB _batch = _BatchGB.gb20;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_count == null) _load();
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
    final downloads = ref.read(downloadsProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
      _current = '';
    });
    try {
      final r = await downloads.downloadMore(
        budgetBytes: _batch.bytes,
        onProgress: (done, total, title) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _current = title;
          });
        },
      );
      if (r.downloaded == 0 && r.failed == 0) {
        messenger.showSnackBar(const SnackBar(content: Text('Новых песен на сервере не осталось')));
      } else {
        final failedNote = r.failed > 0 ? ', не вышло — ${r.failed}' : '';
        messenger.showSnackBar(SnackBar(
          content: Text('Докачано: ${r.downloaded}$failedNote (${_fmtBytes(r.bytes)})'),
        ));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Сервер не ответил — попробуй ещё раз')));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

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
      appBar: AppBar(title: const Text('Библиотека')),
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
            Text(
              _total == 0 ? 'Спрашиваю сервер…' : 'Скачано $_done из $_total',
              style: const TextStyle(color: Afisha.inkDim),
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

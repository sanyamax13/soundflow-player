import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';

/// «Сервер» — состояние домашнего сервера, устройства, лента событий.
/// PIN нет: плеер личный, сервер в домашней сети.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const {};
  List<Map<String, dynamic>> _devices = const [];
  List<Map<String, dynamic>> _events = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final st = await api.adminStatus();
      final dv = await api.adminDevices();
      final ev = await api.adminEvents(limit: 20);
      if (!mounted) return;
      setState(() {
        _status = st;
        _devices = dv;
        _events = ev;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Сервер недоступен';
        _loading = false;
      });
    }
  }

  String _size(num bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
    return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  }

  String _uptime(num sec) {
    final s = sec.toInt();
    if (s >= 3600) return '${s ~/ 3600} ч ${(s % 3600) ~/ 60} мин';
    if (s >= 60) return '${s ~/ 60} мин';
    return '$s с';
  }

  String _when(String? iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сервер')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView()
                : _body(),
      ),
    );
  }

  Widget _errorView() => ListView(
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.cloud_off, color: Afisha.inkDim, size: 56),
          const SizedBox(height: 12),
          Center(child: Text(_error!, style: const TextStyle(color: Afisha.inkDim))),
          const SizedBox(height: 12),
          Center(
            child: FilledButton(onPressed: _load, child: const Text('Повторить')),
          ),
        ],
      );

  Widget _body() {
    final db = '${_status['db'] ?? '—'}';
    final catalog = (_status['catalog'] as Map?) ?? const {};
    final events = (_status['events'] as Map?) ?? const {};
    final byKind = (events['by_kind'] as Map?) ?? const {};
    final legacy = (_status['legacy'] as Map?) ?? const {};

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _section('Сервер'),
        _kv('База данных', db == 'ok' ? 'на связи' : db),
        _kv('Работает', _uptime((_status['uptime_sec'] as num?) ?? 0)),
        _kv('Версия Go', '${_status['go_version'] ?? '—'}'),
        _kv('Источник музыки', '${_status['music_source'] ?? '—'}'),
        _kv('Миграции', '${((_status['migrations'] as List?) ?? const []).length}'),
        _section('Каталог'),
        _kv('Треков', '${catalog['tracks'] ?? 0}'),
        _kv('Файлов', '${catalog['track_files'] ?? 0}'),
        _kv('Из старого: избранное', '${legacy['favorites'] ?? 0}'),
        _kv('Из старого: скрыто', '${legacy['blocked'] ?? 0}'),
        _section('События'),
        _kv('Всего', '${events['total'] ?? 0}'),
        for (final e in byKind.entries) _kv('  ${e.key}', '${e.value}'),
        _section('Устройства (${_devices.length})'),
        if (_devices.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('пока никто не синхронизировался',
                style: TextStyle(color: Afisha.inkDim)),
          ),
        for (final d in _devices)
          ListTile(
            dense: true,
            title: Text('${d['name']?.toString().isNotEmpty == true ? d['name'] : d['id']}'),
            subtitle: Text(
              '${d['app_version'] ?? '—'} · ${_size((d['music_bytes'] as num?) ?? 0)} · '
              'синк ${_when(d['last_sync_at'] as String?)}',
              style: const TextStyle(color: Afisha.inkDim),
            ),
          ),
        _section('Последние события'),
        if (_events.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('пусто', style: TextStyle(color: Afisha.inkDim)),
          ),
        for (final e in _events)
          ListTile(
            dense: true,
            title: Text('${e['kind']}  ${e['track_id'] ?? ''}'),
            subtitle: Text(_when(e['applied_at'] as String?),
                style: const TextStyle(color: Afisha.inkDim)),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: Afisha.lime, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(k, style: const TextStyle(color: Afisha.inkDim))),
            const SizedBox(width: 12),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right, style: const TextStyle(color: Afisha.ink)),
            ),
          ],
        ),
      );
}

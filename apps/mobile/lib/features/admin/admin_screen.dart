import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme.dart';
import 'blocklist_screen.dart';

/// «Сервер» — один собранный экран (Alex 06.09.2026, разбор плеера п. 10):
/// состояние домашнего сервера, синхронизация, устройства, лента событий.
/// PIN нет: плеер личный, сервер в домашней сети. Отчёты, занятое место,
/// очередь скачивания и список «больше не качать» — добавятся, когда появятся
/// на сервере (пункты 4/11/12).
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
  List<Map<String, dynamic>> _srvLog = const [];

  // Синхронизация — раздел свёрнут сюда из отдельного экрана.
  int? _pending;
  DateTime? _lastSync;
  bool _syncBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    final sync = ref.read(syncProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    // Локальные цифры синка — всегда, даже если сервер недоступен.
    try {
      final p = await sync.pendingCount();
      final l = await sync.lastSyncAt();
      if (mounted) {
        setState(() {
          _pending = p;
          _lastSync = l;
        });
      }
    } catch (_) {}
    try {
      final st = await api.adminStatus();
      final dv = await api.adminDevices();
      final ev = await api.adminEvents(limit: 20);
      List<Map<String, dynamic>> sl = const [];
      try {
        sl = await api.serverLog(limit: 60);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _status = st;
        _devices = dv;
        _events = ev;
        _srvLog = sl;
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

  Future<void> _syncNow() async {
    final downloads = ref.read(downloadsProvider);
    final sync = ref.read(syncProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncBusy = true);
    try {
      final bytes = (await downloads.summary()).bytes;
      final r = await sync.sync(musicBytes: bytes);
      messenger.showSnackBar(SnackBar(
        content: Text(
            r.sent == 0 ? 'Новых событий не было' : 'Отправлено событий: ${r.sent}'),
      ));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Сервер не ответил')));
    } finally {
      if (mounted) setState(() => _syncBusy = false);
      await _load();
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
            : _body(),
      ),
    );
  }

  Widget _syncBlock() {
    final pending = _pending;
    String fmt(DateTime? d) {
      if (d == null) return 'ещё не было';
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pending == null
                ? '…'
                : pending == 0
                    ? 'Всё отправлено'
                    : 'Ждут отправки: $pending',
            style: const TextStyle(fontSize: 20, color: Afisha.ink),
          ),
          const SizedBox(height: 4),
          Text('Последняя синхронизация: ${fmt(_lastSync)}',
              style: const TextStyle(color: Afisha.inkDim)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (_syncBusy || pending == null) ? null : _syncNow,
            child: _syncBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Синхронизировать сейчас'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Лайки, удаления и что слушал копятся на телефоне и работают без '
            'сети. Уходят на сервер сами, как появляется связь. Кнопка — если '
            'нужно прямо сейчас.',
            style: TextStyle(color: Afisha.inkDim, height: 1.35, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final db = '${_status['db'] ?? '—'}';
    final catalog = (_status['catalog'] as Map?) ?? const {};
    final events = (_status['events'] as Map?) ?? const {};
    final byKind = (events['by_kind'] as Map?) ?? const {};
    final legacy = (_status['legacy'] as Map?) ?? const {};
    final disk = (_status['disk'] as Map?) ?? const {};
    final report = (_status['report'] as Map?) ?? const {};
    final busy = (_status['busy'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _section('Синхронизация'),
        _syncBlock(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, color: Afisha.inkDim, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(color: Afisha.inkDim)),
                ),
                TextButton(onPressed: _load, child: const Text('Повторить')),
              ],
            ),
          ),
        if (_error != null) const SizedBox(height: 16),
        if (_error == null) ...[
        if (busy.isNotEmpty) ...[
          _section('Сейчас занят'),
          for (final b in busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
              child: Row(
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('$b',
                          style: const TextStyle(color: Afisha.ink))),
                ],
              ),
            ),
        ],
        _section('Сервер'),
        _kv('База данных', db == 'ok' ? 'на связи' : db),
        _kv('Работает', _uptime((_status['uptime_sec'] as num?) ?? 0)),
        _kv('Версия Go', '${_status['go_version'] ?? '—'}'),
        _kv('Источник музыки', '${_status['music_source'] ?? '—'}'),
        _kv('Миграции', '${((_status['migrations'] as List?) ?? const []).length}'),
        _section('Каталог'),
        _kv('Треков', '${catalog['tracks'] ?? 0}'),
        _kv('Файлов', '${catalog['track_files'] ?? 0}'),
        if (disk['music_bytes'] != null)
          _kv('Музыка занимает', _size((disk['music_bytes'] as num?) ?? 0)),
        _kv('Из старого: избранное', '${legacy['favorites'] ?? 0}'),
        if (disk.isNotEmpty) ...[
          _section('Место на диске'),
          _kv('Свободно', _size((disk['free_bytes'] as num?) ?? 0)),
          _kv('Всего на диске', _size((disk['total_bytes'] as num?) ?? 0)),
        ],
        if (report.isNotEmpty) ...[
          _section('Отчёт за 30 дней'),
          _kv('Добавлено', '${report['added'] ?? 0}'),
          _kv('Убрано', '${report['removed'] ?? 0}'),
          _kv('Не нашлось', '${report['not_found'] ?? 0}'),
          _kv('Заменено на лучше', '${report['replaced'] ?? 0}'),
          _kv('Освобождено места', _size((report['freed_bytes'] as num?) ?? 0)),
          if (((report['errors'] as num?) ?? 0) > 0)
            _kv('Ошибок', '${report['errors']}'),
        ],
        _section('Больше не качать'),
        ListTile(
          dense: true,
          title: const Text('Список «больше не качать»'),
          subtitle: Text('${legacy['blocked'] ?? 0} записей',
              style: const TextStyle(color: Afisha.inkDim)),
          trailing: const Icon(Icons.chevron_right, color: Afisha.line),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const BlocklistScreen()),
          ),
        ),
        _section('Что делал сервер'),
        if (_srvLog.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('пока пусто', style: TextStyle(color: Afisha.inkDim)),
          ),
        for (final e in _srvLog) _logRow(e),
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
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _logRow(Map<String, dynamic> e) {
    final kind = '${e['kind']}';
    final artist = '${e['artist'] ?? ''}'.trim();
    final title = '${e['title'] ?? ''}'.trim();
    final name = [title, artist].where((x) => x.isNotEmpty).join(' — ');
    final detail = '${e['detail'] ?? ''}'.trim();
    final style = _logStyle(kind);
    return ListTile(
      dense: true,
      leading: Icon(style.$1, color: style.$2, size: 20),
      title: Text(name.isEmpty ? detail : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [detail, _when(e['at'] as String?)].where((x) => x.isNotEmpty).join('  ·  '),
        style: const TextStyle(color: Afisha.inkDim),
      ),
    );
  }

  (IconData, Color) _logStyle(String kind) {
    switch (kind) {
      case 'added':
        return (Icons.add_circle_outline, Afisha.lime);
      case 'removed':
        return (Icons.remove_circle_outline, Afisha.inkDim);
      case 'replaced':
        return (Icons.autorenew, Afisha.lime);
      case 'not_found':
        return (Icons.search_off, Afisha.inkDim);
      case 'error':
        return (Icons.error_outline, Color(0xFFFF6B6B));
      default:
        return (Icons.circle, Afisha.inkDim);
    }
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/server_discovery.dart';
import '../../core/theme.dart';
import '../../data/api.dart';

/// Адрес сервера — компьютера с программой SoundFlow в домашней сети.
/// Пользователь вписывает адрес (напр. 192.168.1.104), порт 8090
/// подставляется сам. Выбор сохраняется в базе телефона (`server_url`).
class ServerUrlScreen extends ConsumerStatefulWidget {
  const ServerUrlScreen({super.key});

  @override
  ConsumerState<ServerUrlScreen> createState() => _ServerUrlScreenState();
}

class _ServerUrlScreenState extends ConsumerState<ServerUrlScreen> {
  late final TextEditingController _ctrl;
  bool _checking = false;
  bool _saving = false;
  bool _scanning = false;
  bool? _reachable; // null — ещё не проверяли

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(apiProvider).baseUrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _reachable = null;
    });
    final ok = await Api.ping(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _reachable = ok;
    });
  }

  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _scanning = true;
      _reachable = null;
    });
    final found = await discoverServer()
        .timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (!mounted) return;
    setState(() => _scanning = false);
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не нашёл в сети — впиши адрес вручную')),
      );
      return;
    }
    _ctrl.text = found;
    await _check();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final api = ref.read(apiProvider);
    final db = ref.read(dbProvider);
    api.setBaseUrl(_ctrl.text);
    await db.kvSet('server_url', api.baseUrl);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Адрес сохранён: ${api.baseUrl}')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Адрес сервера')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Адрес компьютера, где запущена программа SoundFlow, в домашней '
            'сети. Например: 192.168.1.104 — порт 8090 подставится сам.',
            style: TextStyle(color: Afisha.inkDim),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _checking || _saving || _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox(
                      height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: Text(_scanning ? 'Ищу в сети…' : 'Найти сервер самому'),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Адрес',
              hintText: '192.168.1.104',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _reachable = null),
          ),
          const SizedBox(height: 12),
          if (_reachable != null)
            Row(
              children: [
                Icon(
                  _reachable! ? Icons.check_circle : Icons.error_outline,
                  color: _reachable! ? Afisha.lime : Colors.redAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _reachable! ? 'Сервер ответил' : 'Сервер не ответил по этому адресу',
                  style: TextStyle(
                    color: _reachable! ? Afisha.ink : Colors.redAccent,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _checking || _saving || _scanning ? null : _check,
                  child: _checking
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Проверить'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _checking || _saving || _scanning ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Сохранить'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _checking || _saving || _scanning
                  ? null
                  : () => setState(() {
                        _ctrl.text = kDefaultApiBase;
                        _reachable = null;
                      }),
              child: const Text('Вернуть обычный адрес'),
            ),
          ),
        ],
      ),
    );
  }
}

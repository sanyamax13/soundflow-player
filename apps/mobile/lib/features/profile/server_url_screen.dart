import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:solar_icons/solar_icons.dart';

import '../../app/providers.dart';
import '../../core/config.dart';
import '../../core/notice.dart';
import '../../core/pairing_flow.dart';
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
    var who = '';
    final r = await findAndPair(ref.read(apiProvider), ref.read(dbProvider), name: (n) => who = n);
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _ctrl.text = ref.read(apiProvider).baseUrl;
      _reachable = r == PairResult.connected ? true : _reachable;
    });
    showPairResult(r, who);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    await persistServer(ref.read(apiProvider), ref.read(dbProvider), _ctrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    Notice.show('Адрес сохранён', subtitle: ref.read(apiProvider).baseUrl, kind: NoticeKind.done);
    Navigator.of(context).pop();
  }

  /// Раньше называлась «Вернуть обычный адрес» и молча подставляла хардкод
  /// 127.0.0.1:8090 (USB по умолчанию) — если реальный сервер жил на другом
  /// Wi-Fi адресе, это тихо ломало связь без пути назад (пункт 5). Теперь
  /// возвращает последний АДРЕС, КОТОРЫЙ РЕАЛЬНО РАБОТАЛ; обычный USB-адрес —
  /// только если рабочего ещё ни разу не было.
  Future<void> _restoreLastGood() async {
    final db = ref.read(dbProvider);
    final last = await db.kvGet(kLastGoodUrl);
    if (!mounted) return;
    setState(() {
      _ctrl.text = last ?? kDefaultApiBase;
      _reachable = null;
    });
    if (last == null) {
      Notice.show('Рабочий адрес ещё не запоминали',
          subtitle: 'Подставил обычный (USB)', kind: NoticeKind.warn);
    }
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
                  : const Icon(SolarIconsOutline.magnifier),
              label: Text(_scanning ? 'Поиск в сети…' : 'Найти сервер самому'),
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
                  _reachable! ? SolarIconsBold.checkCircle : SolarIconsOutline.dangerCircle,
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
              onPressed: _checking || _saving || _scanning ? null : _restoreLastGood,
              child: const Text('Вернуть последний рабочий адрес'),
            ),
          ),
        ],
      ),
    );
  }
}

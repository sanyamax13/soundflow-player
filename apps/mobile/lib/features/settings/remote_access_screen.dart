import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
import '../../core/config.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';

/// «Настройки → Удалённый доступ» (Alex TG 24.09.2026, вместо Tailscale —
/// заблокирован для России, см. docs/TAILSCALE-REMOTE-ACCESS-PLAN.md).
/// Обычно телефон видит компьютер только дома, по Wi-Fi или кабелю. Этот
/// переключатель отправляет запросы через собственный сервер Alex-а (VDS) —
/// тогда музыка играет и скачивается из любого места с интернетом.
///
/// Адрес и секретный ключ телефон получает САМ — один раз, в момент, когда
/// подключался к компьютеру дома по Wi-Fi (server_url_screen.dart). Здесь их
/// не вводят руками — только переключатель («сам решаю», Alex TG 14.09.2026).
class RemoteAccessScreen extends ConsumerStatefulWidget {
  const RemoteAccessScreen({super.key});

  @override
  ConsumerState<RemoteAccessScreen> createState() => _RemoteAccessScreenState();
}

class _RemoteAccessScreenState extends ConsumerState<RemoteAccessScreen> {
  bool _loading = true;
  bool _enabled = false;
  String? _relayUrl;
  String? _relayKey;
  String? _localUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final relayUrl = await db.kvGet('relay_url');
    final relayKey = await db.kvGet('relay_key');
    final localUrl = await db.kvGet('server_url');
    final enabled = await db.kvGet('relay_enabled') == '1';
    if (!mounted) return;
    setState(() {
      _relayUrl = relayUrl;
      _relayKey = relayKey;
      _localUrl = localUrl;
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _toggle(bool v) async {
    final db = ref.read(dbProvider);
    final api = ref.read(apiProvider);
    if (v) {
      final url = _relayUrl;
      final key = _relayKey;
      if (url == null || key == null) return;
      api.setRelayTransport(url, key);
      final home = await db.kvGet('server_url');
      if (home != null && home.isNotEmpty) api.setHomeUrl(home);
      unawaited(api.pickRoute());
    } else {
      api.disableRelay(_localUrl ?? kDefaultApiBase);
    }
    await db.kvSet('relay_enabled', v ? '1' : '0');
    if (!mounted) return;
    setState(() => _enabled = v);
    Notice.show(
      v ? 'Удалённый доступ включён' : 'Удалённый доступ выключен',
      subtitle: v ? 'Связь идёт через интернет' : 'Связь снова только дома',
      kind: NoticeKind.done,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Удалённый доступ')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    'Обычно телефон видит компьютер только дома, по Wi-Fi или '
                    'кабелю. Включите — и музыка будет играть и скачиваться из '
                    'любого места, где есть интернет.',
                    style: TextStyle(color: Afisha.inkDim, height: 1.3),
                  ),
                ),
                if (_relayUrl == null || _relayKey == null)
                  AppleSection(
                    dividerInset: 58,
                    children: [
                      AppleRow(
                        icon: CupertinoIcons.globe,
                        iconBg: Afisha.gray,
                        title: 'Пока недоступно',
                        subtitle:
                            'Сначала подключитесь к компьютеру дома по Wi-Fi '
                            '(«Настройки → Адрес сервера → Найти сервер '
                            'самому») — тогда здесь появится переключатель.',
                      ),
                    ],
                  )
                else
                  AppleSection(
                    dividerInset: 58,
                    footer: _enabled
                        ? 'Работает через интернет. Отключите, когда снова '
                            'дома — так надёжнее и быстрее.'
                        : null,
                    children: [
                      AppleRow(
                        icon: CupertinoIcons.globe,
                        iconBg: Afisha.green,
                        title: 'Удалённый доступ',
                        subtitle: _enabled
                            ? 'Включён — связь через интернет'
                            : 'Выключен — связь только дома',
                        trailing: CupertinoSwitch(
                          value: _enabled,
                          onChanged: _toggle,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
    );
  }
}

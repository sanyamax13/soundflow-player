import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
import '../../core/crash_log.dart';
import '../../core/net_hint.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';
import '../../core/update_check.dart';
import '../../core/update_download.dart';
import '../admin/admin_screen.dart';
import '../discover/discover_screen.dart';
import '../sync/sync_offer_card.dart';
import '../settings/settings_screen.dart';
import '../taste_review/taste_review_screen.dart';

/// Профиль: синхронизация, статистика, настройки. Оформление — как «Настройки»
/// на iPhone (Alex TG 20345, 21.09.2026): крупный заголовок, который при
/// прокрутке сворачивается, и сгруппированные ряды на серых плашках.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: AppleLargeTitle('Профиль'),
            ),
            const _CrashCard(),
            const SyncOfferCard(showIdle: true),
            const SizedBox(height: 18),
            AppleSection(
              dividerInset: 58,
              children: [
                AppleRow(
                  icon: CupertinoIcons.wand_stars,
                  iconBg: Afisha.lime,
                  title: 'Открытия',
                  subtitle: 'волна по вкусу, плейлист по ссылке — Яндекс и торренты',
                  chevron: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const DiscoverScreen()),
                  ),
                ),
                AppleRow(
                  icon: CupertinoIcons.slider_horizontal_3,
                  iconBg: Afisha.blue,
                  title: 'Разбор коллекции',
                  subtitle: 'послушать и почистить — от менее твоего к более',
                  chevron: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const TasteReviewScreen()),
                  ),
                ),
                AppleRow(
                  icon: CupertinoIcons.desktopcomputer,
                  iconBg: Afisha.blue,
                  title: 'Сервер',
                  subtitle: 'связь с компьютером, полный сброс',
                  chevron: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
                  ),
                ),
                AppleRow(
                  icon: CupertinoIcons.gear_solid,
                  iconBg: Afisha.gray,
                  title: 'Настройки',
                  subtitle: 'адрес сервера, журнал',
                  chevron: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const AppleSection(dividerInset: 58, children: [_UpdateRow()]),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

/// Показывается только если в прошлый раз приложение упало (Alex TG 19028).
/// Тап — весь текст сбоя: можно прочитать, отправить на компьютер, убрать.
class _CrashCard extends ConsumerStatefulWidget {
  const _CrashCard();

  @override
  ConsumerState<_CrashCard> createState() => _CrashCardState();
}

class _CrashCardState extends ConsumerState<_CrashCard> {
  String? _text;

  @override
  void initState() {
    super.initState();
    CrashLog.read().then((t) {
      if (mounted) setState(() => _text = t);
    });
  }

  Future<void> _open() async {
    final text = _text;
    if (text == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Последний сбой'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await ref
                    .read(apiProvider)
                    .reportCrash(await ref.read(syncProvider).deviceId(), text);
                Notice.show('Отправлено на компьютер', kind: NoticeKind.done);
              } catch (_) {
                showServerUnreachable(lead: 'Компьютер сейчас недоступен');
              }
            },
            child: const Text('Отправить на компьютер'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await CrashLog.clear();
              if (mounted) setState(() => _text = null);
            },
            child: const Text('Убрать'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: AppleSection(
        dividerInset: 58,
        children: [
          AppleRow(
            icon: CupertinoIcons.exclamationmark_triangle_fill,
            iconBg: Afisha.red,
            title: 'Приложение падало',
            // Человеческая строка вместо сырого стека (Опус-ревью телефона
            // 14.09.2026, пункт 2) — сам текст сбоя всё ещё доступен по тапу.
            subtitle: 'Есть запись о сбое — нажмите, чтобы посмотреть или отправить',
            chevron: true,
            onTap: _open,
          ),
        ],
      ),
    );
  }
}

/// «О программе» — версия + автопроверка обновления при открытии Профиля
/// (тихо, без всплывающих окон) + тап ставит скачанную версию (Alex,
/// 12.09.2026 — канал vdsmusic.ru, см. core/update_check.dart).
class _UpdateRow extends StatefulWidget {
  const _UpdateRow();

  @override
  State<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends State<_UpdateRow> {
  static const _channel = MethodChannel('soundflow/device');

  String _installed = '…';
  UpdateInfo? _available;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    int code;
    try {
      code = await _channel.invokeMethod<int>('appVersionCode') ?? 0;
    } catch (_) {
      code = 0;
    }
    if (!mounted) return;
    setState(() => _installed = 'v$code');
    final update = await checkForUpdate();
    if (mounted) setState(() => _available = update);
  }

  Future<void> _install() async {
    final u = _available;
    if (u == null || _busy) return;
    setState(() => _busy = true);
    try {
      await downloadAndInstallUpdate(u.apkUrl);
    } catch (_) {
      Notice.show('Не получилось скачать обновление',
          subtitle: 'Проверьте интернет и нажмите ещё раз', kind: NoticeKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _available;
    if (u == null) {
      return AppleRow(
        icon: CupertinoIcons.info,
        iconBg: Afisha.gray,
        title: 'О программе',
        value: _installed,
        onTap: _busy ? null : _load,
      );
    }
    return AppleRow(
      icon: CupertinoIcons.arrow_down_circle_fill,
      iconBg: Afisha.green,
      title: _busy ? 'Скачивание…' : 'Доступно обновление v${u.versionCode}',
      subtitle: u.changelog.isEmpty ? 'нажмите, чтобы поставить' : u.changelog,
      chevron: !_busy,
      onTap: _busy ? null : _install,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/solar.dart';

import '../../app/providers.dart';
import '../../core/apple.dart';
import '../../core/notice.dart';
import '../../core/theme.dart';
import '../../core/update_check.dart';
import '../../core/update_download.dart';
import '../admin/admin_screen.dart';
import '../discover/discover_screen.dart';
import '../sync/sync_offer_card.dart';
import '../player/seek_skin.dart';

/// Профиль. 26.09.2026 (разбор Gemini + Alex «да»): сверху вниз —
/// обновление (только когда есть) · «Медиатека» (вся ли музыка на телефоне) ·
/// «Открытия» · «Связь с домом» с живым статусом прямо в строке (бывшие
/// «Сервер» и «Настройки» слиты в один экран) · «О программе» маленькой строкой.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  static const _channel = MethodChannel('soundflow/device');

  String _installed = '…';
  UpdateInfo? _update;
  bool _updating = false;
  bool? _online; // null — ещё проверяем

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _checkOnline();
  }

  Future<void> _loadVersion() async {
    int code;
    try {
      code = await _channel.invokeMethod<int>('appVersionCode') ?? 0;
    } catch (_) {
      code = 0;
    }
    if (!mounted) return;
    setState(() => _installed = 'v$code');
    final u = await checkForUpdate();
    if (mounted) setState(() => _update = u);
  }

  Future<void> _checkOnline() async {
    try {
      await ref.read(apiProvider).health();
      if (mounted) setState(() => _online = true);
    } catch (_) {
      if (mounted) setState(() => _online = false);
    }
  }

  Future<void> _install() async {
    final u = _update;
    if (u == null || _updating) return;
    setState(() => _updating = true);
    try {
      await downloadAndInstallUpdate(u.apkUrl);
    } catch (_) {
      Notice.show('Не получилось скачать обновление',
          subtitle: 'Проверьте интернет и нажмите ещё раз', kind: NoticeKind.error);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _update;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([_loadVersion(), _checkOnline()]);
          },
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: AppleLargeTitle('Профиль'),
              ),
              if (u != null) _UpdateCard(info: u, busy: _updating, onTap: _install),
              const SyncOfferCard(showIdle: true),
              const SizedBox(height: 18),
              AppleSection(
                dividerInset: 58,
                children: [
                  AppleRow(
                    icon: SolarBold.magicWand,
                    iconBg: Afisha.lime,
                    title: 'Открытия',
                    subtitle: 'новая музыка по вкусу — Яндекс и торренты',
                    chevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const DiscoverScreen()),
                    ),
                  ),
                  // Вид плеера — «Оценка» / «Листание», одно нажатие переключает (Alex TG 22574, 28.09.2026).
                  ValueListenableBuilder<SeekSkin>(
                    valueListenable: seekSkin,
                    builder: (context, skin, _) => AppleRow(
                      key: const ValueKey('profile_seek_skin'),
                      icon: SolarOutline.tuning,
                      iconBg: Afisha.gray,
                      title: 'Вид плеера',
                      value: skin.label,
                      onTap: () => toggleSeekSkin(ref.read(dbProvider)),
                    ),
                  ),
                  AppleRow(
                    icon: SolarBold.home2,
                    iconBg: Afisha.blue,
                    title: 'Связь с домом',
                    trailing: _OnlineBadge(online: _online),
                    chevron: true,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
                      );
                      _checkOnline();
                    },
                  ),
                ],
              ),
              if (u == null) ...[
                const SizedBox(height: 22),
                AppleSection(dividerInset: 58, children: [
                  AppleRow(
                    icon: SolarOutline.infoCircle,
                    iconBg: Afisha.gray,
                    title: 'О программе',
                    value: _installed,
                    onTap: _loadVersion,
                  ),
                ]),
              ],
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}

/// «На связи ●» / «Нет связи ●» прямо в строке «Связь с домом» — видно без захода внутрь.
class _OnlineBadge extends StatelessWidget {
  const _OnlineBadge({required this.online});

  final bool? online;

  @override
  Widget build(BuildContext context) {
    final o = online;
    final color = o == null ? Afisha.inkDim : (o ? Afisha.green : Afisha.red);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(o == null ? 'проверяю…' : (o ? 'На связи' : 'Нет связи'),
            style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w500)),
        const SizedBox(width: 6),
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ],
    );
  }
}

/// Обновление — наверху, одной строкой с кнопкой (разбор Gemini 26.09.2026). Показывается,
/// только когда новая версия есть; иначе внизу тихая строка «О программе».
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.info, required this.busy, required this.onTap});

  final UpdateInfo info;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      decoration: BoxDecoration(
        color: Afisha.lime.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Afisha.lime.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(SolarBold.downloadMinimalistic, color: Afisha.lime, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Новая версия v${info.versionCode}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Afisha.ink, fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: const StadiumBorder(),
            ),
            onPressed: busy ? null : onTap,
            child: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Обновить'),
          ),
        ],
      ),
    );
  }
}


import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/solar.dart';

import '../../app/providers.dart';
import '../../core/glass_sheet.dart';
import '../../core/config.dart';
import '../../core/net_hint.dart';
import '../../core/notice.dart';
import '../../core/pulsing_dot.dart';
import '../../core/theme.dart';
import '../profile/server_url_screen.dart';
import '../settings/remote_access_screen.dart';

/// «Сервер» — упрощено до того, что реально нужно Alex на ЭТОМ экране
/// (Опус-ревью телефона 14.09.2026, пункт 8): связь с компьютером и
/// синхронизация. Версии Go, миграции, сырые виды событий, ID устройств и лог
/// сервера убраны — это разработческая панель, которая только пугала
/// техническим видом и дублирует то, что теперь показывает само окно
/// программы на компьютере (серверный Опус-ревью того же дня). PIN нет: плеер
/// личный, сервер в домашней сети. Список «больше не качать» с 19.09.2026 на
/// телефоне не показывается (Alex TG 19943: «все в программу и все скрыто»):
/// его знает только программа на компьютере.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  bool _loading = true;
  bool _reachable = false;

  int? _pending;
  DateTime? _lastSync;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    final sync = ref.read(syncProvider);
    setState(() => _loading = true);
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
      await api.adminStatus();
      if (!mounted) return;
      setState(() {
        _reachable = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reachable = false;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Связь с домом')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _body(),
      ),
    );
  }

  String _syncTitle() {
    final pending = _pending;
    return pending == null
        ? '…'
        : pending == 0
        ? 'всё передано'
        : 'ждут связи: $pending';
  }

  String _lastSyncText() {
    final d = _lastSync;
    if (d == null) return 'Ещё не обменивались';
    final l = d.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(l.hour)}:${two(l.minute)}';
    final today = l.year == now.year && l.month == now.month && l.day == now.day;
    return today ? 'Обновлено в $time' : 'Обновлено ${two(l.day)}.${two(l.month)} в $time';
  }

  // 25.09.2026 (по разбору Gemini, Alex «да меняй всё»): экран был списком
  // серых карточек «как Настройки на iPhone» — заменён на «живую панель»:
  // пульсирующая точка + крупный статус вместо строки с иконкой, подписи
  // вместо заголовков секций, переключателей тут пока нет (нечего
  // переключать на этом экране — они появятся, если такое понадобится).
  // 26.09.2026 (разбор Gemini «Профиль», Alex «да»): «Сервер» и «Настройки» слиты в
  // один экран. Сверху — состояние, ниже — открытыми строками адрес и удалённый
  // доступ (без раскрывашек: лишнее нажатие), в самом низу красной надписью
  // «Полный сброс» — без «Показать опасное», случайное нажатие ловит вопрос «Стереть?».
  Widget _body() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            PulsingStatusDot(color: _reachable ? Afisha.green : Afisha.red),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _reachable ? 'На связи' : 'Нет связи',
                style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: -1),
              ),
            ),
            if (!_reachable)
              TextButton(onPressed: _load, child: const Text('Проверить')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _reachable ? _lastSyncText() : kServerUnreachableHint,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
        ),
        const SizedBox(height: 28),
        _dashboardItem('История и оценки', _syncTitle(), ok: (_pending ?? 1) == 0),
        const SizedBox(height: 20),
        // Новые песни качаются сами дома по Wi-Fi (разбор Gemini 26.09.2026).
        ListenableBuilder(
          listenable: ref.read(syncOfferProvider),
          builder: (context, _) {
            final offer = ref.read(syncOfferProvider);
            return SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              activeTrackColor: Afisha.lime,
              title: const Text('Качать новое само',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500)),
              subtitle: Text('дома по Wi-Fi, без вопроса',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13)),
              value: offer.autoDownload,
              onChanged: offer.setAutoDownload,
            );
          },
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        _row(
          icon: SolarOutline.wifiRouterMinimalistic,
          iconColor: Afisha.blue,
          title: 'Адрес дома',
          subtitle: apiBase.replaceFirst('http://', ''),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ServerUrlScreen()),
            );
            if (mounted) _load();
          },
        ),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        _row(
          icon: SolarOutline.global,
          iconColor: Afisha.green,
          title: 'Удалённый доступ',
          subtitle: 'слушать не из дома',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RemoteAccessScreen()),
          ),
        ),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        const SizedBox(height: 48),
        Center(
          child: TextButton(
            key: const Key('full-reset'),
            style: TextButton.styleFrom(
              foregroundColor: Afisha.red,
              minimumSize: const Size(200, 56),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: _resetBusy ? null : _confirmReset,
            child: _resetBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Полный сброс'),
          ),
        ),
        const Text(
          'Сотрёт музыку, лайки и историю на этом телефоне. Дома ничего не меняется.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Afisha.inkDim, fontSize: 12),
        ),
      ],
    );
  }

  Widget _row({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13)),
                      ],
                    ],
                  ),
                ),
                Icon(SolarOutline.altArrowRight, color: Colors.white.withValues(alpha: 0.3), size: 16),
              ],
            ),
          ),
        ),
      );

  Widget _dashboardItem(String title, String value, {bool ok = false}) => Row(
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(color: ok ? Afisha.green : Afisha.inkDim, fontSize: 15, fontWeight: FontWeight.w500)),
        ],
      );

  // Alex TG 15.09.2026: «сделай кнопку полный сброс, что бы как первый раз
  // установил и без музыки». Стирает музыку/лайки/историю на ЭТОМ телефоне;
  // адрес сервера и id телефона не трогает (иначе на компе появится ещё одна
  // запись-«призрак» устройства — та самая проблема, что только что чинили).
  bool _resetBusy = false;

  Future<void> _confirmReset() async {
    // Шторка снизу: «Отмена» лаймом слева, «Стереть всё» красным справа (разбор Gemini и Алисы 27.09.2026).
    final ok = await confirmSheet(
      context,
      title: 'Полный сброс?',
      body: 'Удалит всю скачанную музыку, лайки и историю на этом телефоне. Отменить нельзя.',
      okLabel: 'Стереть всё',
      danger: true,
    );
    if (!ok || !mounted) return;
    final downloads = ref.read(downloadsProvider);
    setState(() => _resetBusy = true);
    try {
      await downloads.fullReset();
      Notice.show(
        'Готово',
        subtitle: 'Телефон как новый',
        kind: NoticeKind.done,
      );
    } catch (e) {
      Notice.show('Не вышло', subtitle: '$e', kind: NoticeKind.error);
    } finally {
      if (mounted) setState(() => _resetBusy = false);
      await _load();
    }
  }
}

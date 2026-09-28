import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/solar.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../core/pairing_flow.dart';
import '../../core/theme.dart';

/// Первый запуск на новом телефоне (своя копия плеера у другого человека, Alex 28.09.2026, вариант
/// «А»: без QR). Компьютер ещё не знаком — одна большая кнопка «Найти компьютер»: телефон ищет
/// SoundFlow в Wi-Fi и подключается, если на компьютере открыто «Подключить телефон» (мастер первого
/// запуска на компьютере открывает его сам). Вместе с адресом приходит и связь через ВДС.
/// «Позже» — сразу в плеер; подключиться можно в Профиле → «Адрес сервера».
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  bool _busy = false;

  void _toShell() {
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const Shell()));
  }

  Future<void> _find() async {
    setState(() => _busy = true);
    var who = '';
    final r = await findAndPair(ref.read(apiProvider), ref.read(dbProvider), name: (n) => who = n);
    if (!mounted) return;
    setState(() => _busy = false);
    showPairResult(r, who);
    if (r == PairResult.connected) _toShell();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(SolarOutline.monitor, size: 56, color: Afisha.lime),
              const SizedBox(height: 24),
              const Text('Подключите компьютер',
                  style: TextStyle(color: Afisha.ink, fontSize: 30, fontWeight: FontWeight.w700, height: 1.15)),
              const SizedBox(height: 16),
              const _Step(n: 1, text: 'На компьютере откройте SoundFlow — после настройки там открыто окно «Подключить телефон».'),
              const _Step(n: 2, text: 'Телефон — в том же Wi-Fi, что и компьютер.'),
              const _Step(n: 3, text: 'Нажмите «Найти компьютер». Вне дома музыка потом будет идти через ваш ВДС сама.'),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: FilledButton(
                  key: const ValueKey('connect_find'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Afisha.lime,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    textStyle: const TextStyle(fontFamily: Afisha.fontFamily, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _find,
                  child: _busy
                      ? const Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black)),
                          SizedBox(width: 12),
                          Text('Ищу в сети…'),
                        ])
                      : const Text('Найти компьютер'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: TextButton(
                  key: const ValueKey('connect_later'),
                  onPressed: _busy ? null : _toShell,
                  child: const Text('Позже', style: TextStyle(color: Afisha.inkDim, fontSize: 17)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Afisha.surfaceHi, shape: BoxShape.circle),
            child: Text('$n', style: const TextStyle(color: Afisha.lime, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(color: Afisha.inkDim, fontSize: 16, height: 1.35))),
        ]),
      );
}

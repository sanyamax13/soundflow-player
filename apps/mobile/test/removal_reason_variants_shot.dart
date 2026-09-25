// Два варианта оформления листа причин «Убрать совсем», поверх похожего на
// настоящий экран плеера (Alex TG 25.09.2026: «ещё варианты под эпл... сделай
// на живом примере») — не проверка логики, только картинки для показа.
// Запуск:
//   flutter test --update-goldens test/removal_reason_variants_shot.dart
// Картинки: test/goldens/removal_reason_variant_a.png (классический iOS action
// sheet — по центру, с «Отмена» отдельной плашкой) и variant_b.png (список
// строкой, как остальные экраны приложения).

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/apple.dart';
import 'package:soundflow/core/removal_reasons.dart';
import 'package:soundflow/core/theme.dart';

/// Фон, похожий на настоящий плеер — во весь экран размытая обложка (как
/// реально сделано в плеере — фон-подложка под цвет обложки), сверху сама
/// обложка, название, controls. Во весь экран и с цветом — чтобы у
/// «стеклянного» варианта было что просвечивать, иначе матовость не видно.
Widget _playerMock() => Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6B3FA0), Color(0xFF1B1030), Color(0xFF0A1A2E)],
            ),
          ),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: const SizedBox.expand(),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF3A2E5C), Color(0xFF171022)],
                      ),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 12))],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Text('Би-2', style: TextStyle(color: Afisha.ink, fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Варвара', style: TextStyle(color: Afisha.inkDim, fontSize: 17)),
              ],
            ),
          ),
        ),
      ],
    );

/// Вариант А — классический action sheet iOS: заголовок по центру серым,
/// причины по центру (красный — необратимое действие), отдельной плашкой
/// снизу «Отмена».
Future<String?> _pickReasonVariantA(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ColoredBox(
                color: const Color(0xFF2C2C2E),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Text(
                        'Причина удаления',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Afisha.inkDim, letterSpacing: -0.1),
                      ),
                    ),
                    for (final e in kRemovalReasons.entries) ...[
                      const Divider(height: 0.5, thickness: 0.5, color: Afisha.sep),
                      InkWell(
                        onTap: () => Navigator.pop(ctx, e.key),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            e.value,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 20, color: Afisha.red, letterSpacing: -0.4),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ColoredBox(
                color: const Color(0xFF2C2C2E),
                child: InkWell(
                  onTap: () => Navigator.pop(ctx, null),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      'Отмена',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Afisha.blue, letterSpacing: -0.4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Вариант В — «Liquid Glass» (Alex TG 25.09.2026: «сделай ещё вариант на iOS
/// 27»). Честно: точных макетов iOS 27 у меня нет (после моего среза знаний),
/// беру общее направление, которое Apple показала на WWDC 2025 и продолжает —
/// матовое полупрозрачное стекло с размытием фона, более крупное скругление,
/// плавающие отдельные плашки вместо плоских непрозрачных карточек.
Future<String?> _pickReasonVariantGlass(BuildContext context) {
  Widget glass({required Widget child, double radius = 26}) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: child,
          ),
        ),
      );
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            glass(
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
                    child: Text(
                      'Причина удаления',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Afisha.inkDim, letterSpacing: -0.1),
                    ),
                  ),
                  for (final e in kRemovalReasons.entries) ...[
                    Divider(height: 0.5, thickness: 0.5, color: Colors.white.withValues(alpha: 0.12)),
                    InkWell(
                      onTap: () => Navigator.pop(ctx, e.key),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        child: Text(
                          e.value,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 19, color: Afisha.red, letterSpacing: -0.3, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            glass(
              radius: 26,
              child: InkWell(
                onTap: () => Navigator.pop(ctx, null),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 15),
                  child: Text(
                    'Отмена',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Вариант Г — «iOS 27» + «One UI 8.5» вместе (Alex TG 25.09.2026). Честно:
/// точных макетов НИ ОДНОЙ из двух версий у меня нет (после среза знаний) —
/// это моя добросовестная догадка-синтез, не копия реального экрана. Беру у
/// «стекла» (iOS) — размытие/полупрозрачность; у One UI — более крупное
/// скругление и один цельный лист (Samsung обычно не дробит на отдельные
/// плашки, как iOS), текст слева, а не по центру, и крупный акцентный цвет
/// (фирменный лайм этого приложения — вместо синего/жёлтого Samsung) на
/// «Отмена», а не отдельным блоком снизу.
Future<String?> _pickReasonVariantFusion(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(34),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(34),
                color: Colors.white.withValues(alpha: 0.14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 22, 24, 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Причина удаления',
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.3),
                      ),
                    ),
                  ),
                  for (final e in kRemovalReasons.entries)
                    InkWell(
                      onTap: () => Navigator.pop(ctx, e.key),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            e.value,
                            style: const TextStyle(fontSize: 18, color: Colors.white, letterSpacing: -0.2),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => Navigator.pop(ctx, null),
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: Afisha.lime,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Text(
                        'Отмена',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black, letterSpacing: -0.2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _app(Future<String?> Function(BuildContext) opener) => Builder(
      builder: (context) => Stack(
        children: [
          _playerMock(),
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton(
                onPressed: () => opener(context),
                child: const Text('открыть'),
              ),
            ),
          ),
        ],
      ),
    );

void main() {
  setUpAll(() async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
  });

  testWidgets('вариант А — классический action sheet iOS, с «Отмена»', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: _app(_pickReasonVariantA),
    ));
    await t.tap(find.text('открыть'));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/removal_reason_variant_a.png'));
  });

  testWidgets('вариант Б — список строкой (тот же, что и в приложении сейчас)', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: _app(pickRemovalReason),
    ));
    await t.tap(find.text('открыть'));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/removal_reason_variant_b.png'));
  });

  testWidgets('вариант В — матовое стекло (направление iOS 26/27)', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: _app(_pickReasonVariantGlass),
    ));
    await t.tap(find.text('открыть'));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/removal_reason_variant_c_glass.png'));
  });

  testWidgets('вариант Г — синтез iOS 27 + One UI 8.5 (добросовестная догадка)', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: _app(_pickReasonVariantFusion),
    ));
    await t.tap(find.text('открыть'));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/removal_reason_variant_d_fusion.png'));
  });
}

import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('default preset at t = 0.18, 400x400', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          child: CustomPaint(
            size: const Size(400, 400),
            painter: OrbPainter(seconds: 0.18 * 12, preset: OrbPreset.defaults),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/orb_default_t0.18_400x400.png'),
    );
  });
}

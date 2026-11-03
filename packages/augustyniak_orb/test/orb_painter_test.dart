import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _still = 0.18 * 12;

Future<Uint8List> _raw(double seconds, OrbPreset preset) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  OrbPainter(
    seconds: seconds,
    preset: preset,
  ).paint(Canvas(recorder), const Size(200, 200));
  final ui.Image image = await recorder.endRecording().toImage(200, 200);
  final ByteData? data = await image.toByteData();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _render(double seconds, OrbPreset preset) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  const Size size = Size(200, 200);
  OrbPainter(seconds: seconds, preset: preset).paint(Canvas(recorder), size);
  final ui.Image image = await recorder.endRecording().toImage(200, 200);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

OrbPreset _without(OrbLayers layers) => OrbPreset(
  palette: OrbPalette.defaults,
  tuning: OrbTuning.defaults,
  layers: layers,
);

void main() {
  testWidgets('same seconds and preset paint identical pictures', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Uint8List a = await _render(_still, OrbPreset.defaults);
      final Uint8List b = await _render(_still, OrbPreset.defaults);
      expect(a, b);
    });
  });

  testWidgets('different seconds paint a different picture', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Uint8List a = await _render(_still, OrbPreset.defaults);
      final Uint8List b = await _render(_still + 1.3, OrbPreset.defaults);
      expect(a, isNot(b));
    });
  });

  testWidgets('one period apart is the same picture (seamless loop)', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Uint8List a = await _raw(_still, OrbPreset.defaults);
      final Uint8List b = await _raw(_still + 12, OrbPreset.defaults);
      int worst = 0;
      for (int i = 0; i < a.length; i++) {
        worst = math.max(worst, (a[i] - b[i]).abs());
      }
      // Float rounding of t may move an antialiased edge by a level or two.
      expect(worst, lessThanOrEqualTo(4));
    });
  });

  testWidgets('each layer switch changes the picture', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Uint8List base = await _render(_still, OrbPreset.defaults);
      final Map<String, OrbLayers> off = <String, OrbLayers>{
        'grid': const OrbLayers(grid: false),
        'pulses': const OrbLayers(pulses: false),
        'spokes': const OrbLayers(spokes: false),
        'rings': const OrbLayers(rings: false),
        'sweep': const OrbLayers(sweep: false),
        'core': const OrbLayers(core: false),
      };
      for (final MapEntry<String, OrbLayers> e in off.entries) {
        expect(
          await _render(_still, _without(e.value)),
          isNot(base),
          reason: '${e.key} off must change the picture',
        );
      }
    });
  });
}

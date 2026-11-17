import 'dart:ui' as ui;

import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts the draw calls the painter makes; every other call is ignored.
class _CountingCanvas implements Canvas {
  int lines = 0;
  int arcs = 0;
  int circles = 0;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines++;

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) => arcs++;

  @override
  void drawCircle(Offset c, double radius, Paint paint) => circles++;

  @override
  void drawRect(ui.Rect rect, ui.Paint paint) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const OrbLayers _spokesOnly = OrbLayers(
  grid: false,
  pulses: false,
  rings: false,
  sweep: false,
  core: false,
);

const OrbLayers _ringsOnly = OrbLayers(
  grid: false,
  pulses: false,
  spokes: false,
  sweep: false,
  core: false,
);

_CountingCanvas _paint(OrbPreset preset) {
  final _CountingCanvas canvas = _CountingCanvas();
  OrbPainter(
    seconds: 0.18 * 12,
    preset: preset,
  ).paint(canvas, const Size(400, 400));
  return canvas;
}

/// Each particle is a dot, a glow and a five-step comet tail.
const int _circlesPerDot = 7;

/// Every ring draws half of its 36 dash slots.
const int _arcsPerRing = 18;

void main() {
  test('the default preset paints 72 spokes and 5/7/4 particles', () {
    expect(_paint(const OrbPreset(layers: _spokesOnly)).lines, 72);
    final _CountingCanvas rings = _paint(const OrbPreset(layers: _ringsOnly));
    expect(rings.arcs, 3 * _arcsPerRing);
    expect(rings.circles, (5 + 7 + 4) * _circlesPerDot);
  });

  test('a preset exported with spokeCount and dots paints those counts', () {
    // The shape `augustyniak.ai/orb` exports: JSON with the v1 tuning keys.
    final OrbPreset exported = OrbPreset.fromJson(<String, Object?>{
      'v': 1,
      'tuning': <String, Object?>{
        'spokeCount': 144,
        'dots': <Object?>[0, 12, 3],
      },
    });
    expect(
      _paint(OrbPreset(tuning: exported.tuning, layers: _spokesOnly)).lines,
      144,
    );
    final _CountingCanvas rings = _paint(
      OrbPreset(tuning: exported.tuning, layers: _ringsOnly),
    );
    expect(rings.arcs, 3 * _arcsPerRing);
    expect(rings.circles, (0 + 12 + 3) * _circlesPerDot);
  });
}

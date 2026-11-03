import 'dart:convert';

import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OrbPreset JSON', () {
    test('defaults match the shared contract', () {
      final Map<String, Object?> json = OrbPreset.defaults.toJson();
      expect(json['v'], 1);
      expect(json['palette'], <String, Object?>{
        'accent': '#59A0F8',
        'violet': '#AC8BF9',
        'pink': '#F472B6',
        'grid': '#35353B',
        'backdrop': '#1D1D20',
      });
      expect(json['tuning'], <String, Object?>{
        'speed': 1.0,
        'period': 12.0,
        'centerY': 0.44,
        'radiusScale': 1.0,
        'gridStep': 36.0,
        'pulse': 3.0,
        'spokeFast': 4.0,
        'spokeSlow': 2.0,
        'rings': <double>[1, -2, 2],
        'sweep': 2.0,
        'breath': 6.0,
        'gridScroll': 12.0,
      });
      expect(json['layers'], <String, Object?>{
        'grid': true,
        'pulses': true,
        'spokes': true,
        'rings': true,
        'sweep': true,
        'core': true,
      });
    });

    test('round-trips through JSON text without loss', () {
      const OrbPreset preset = OrbPreset(
        palette: OrbPalette(
          accent: Color(0xFF112233),
          violet: Color(0xFF445566),
          pink: Color(0xFF778899),
          grid: Color(0xFFAABBCC),
          backdrop: Color(0xFF010203),
        ),
        tuning: OrbTuning(
          speed: 0.5,
          period: 20,
          centerY: 0.5,
          radiusScale: 0.8,
          gridStep: 24,
          pulse: 2,
          spokeFast: 3,
          spokeSlow: 1,
          rings: <double>[2, -1, 3],
          sweep: 4,
          breath: 5,
          gridScroll: 6,
        ),
        layers: OrbLayers(grid: false, sweep: false),
      );
      final OrbPreset back = OrbPreset.fromJson(
        jsonDecode(jsonEncode(preset.toJson())) as Map<String, Object?>,
      );
      expect(back, preset);
      expect(back.toJson(), preset.toJson());
    });

    test('missing keys take the defaults', () {
      final OrbPreset p = OrbPreset.fromJson(<String, Object?>{'v': 1});
      expect(p, OrbPreset.defaults);
      final OrbPreset partial = OrbPreset.fromJson(<String, Object?>{
        'v': 1,
        'tuning': <String, Object?>{'speed': 2},
        'layers': <String, Object?>{'core': false},
      });
      expect(partial.tuning.speed, 2.0);
      expect(partial.tuning.period, 12.0);
      expect(partial.layers.core, isFalse);
      expect(partial.layers.grid, isTrue);
      expect(partial.palette, OrbPalette.defaults);
    });

    test('unknown keys are ignored', () {
      final OrbPreset p = OrbPreset.fromJson(<String, Object?>{
        'v': 1,
        'extra': 1,
        'tuning': <String, Object?>{'warp': 9},
        'layers': <String, Object?>{'fog': true},
        'palette': <String, Object?>{'gold': '#FFD700'},
      });
      expect(p, OrbPreset.defaults);
    });

    test('an unparsable colour takes the default colour', () {
      final OrbPreset p = OrbPreset.fromJson(<String, Object?>{
        'v': 1,
        'palette': <String, Object?>{
          'accent': 'blue',
          'violet': '#12345',
          'pink': 42,
          'grid': '#GGGGGG',
          'backdrop': '#000000',
        },
      });
      expect(p.palette.accent, OrbPalette.defaults.accent);
      expect(p.palette.violet, OrbPalette.defaults.violet);
      expect(p.palette.pink, OrbPalette.defaults.pink);
      expect(p.palette.grid, OrbPalette.defaults.grid);
      expect(p.palette.backdrop, const Color(0xFF000000));
    });

    test('bad tuning values take the defaults', () {
      final OrbPreset p = OrbPreset.fromJson(<String, Object?>{
        'v': 1,
        'tuning': <String, Object?>{
          'speed': 'fast',
          'period': 0,
          'rings': <Object?>[1, 2],
          'sweep': 3,
        },
      });
      expect(p.tuning.speed, 1.0);
      expect(p.tuning.period, 12.0);
      expect(p.tuning.rings, <double>[1, -2, 2]);
      expect(p.tuning.sweep, 3.0);
    });

    test('an unknown or missing version is rejected as the defaults', () {
      final Map<String, Object?> tweaked = <String, Object?>{
        'tuning': <String, Object?>{'speed': 3},
      };
      expect(
        OrbPreset.fromJson(<String, Object?>{...tweaked, 'v': 2}),
        OrbPreset.defaults,
      );
      expect(OrbPreset.fromJson(tweaked), OrbPreset.defaults);
    });
  });
}

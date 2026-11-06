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
        'spokeCount': 72,
        'dots': <int>[5, 7, 4],
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
          spokeCount: 120,
          dots: <int>[0, 12, 24],
        ),
        layers: OrbLayers(grid: false, sweep: false),
      );
      final OrbPreset back = OrbPreset.fromJson(
        jsonDecode(jsonEncode(preset.toJson())),
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

    test('legacy tuning without spokeCount or dots parses as before', () {
      final OrbPreset legacy = OrbPreset.fromJson(<String, Object?>{
        'v': 1,
        'tuning': <String, Object?>{
          'speed': 1,
          'period': 12,
          'centerY': 0.44,
          'radiusScale': 1,
          'gridStep': 36,
          'pulse': 3,
          'spokeFast': 4,
          'spokeSlow': 2,
          'rings': <Object?>[1, -2, 2],
          'sweep': 2,
          'breath': 6,
          'gridScroll': 12,
        },
      });
      expect(legacy, OrbPreset.defaults);
      expect(legacy.tuning.spokeCount, 72);
      expect(legacy.tuning.dots, <int>[5, 7, 4]);
    });

    test('spokeCount clamps to 12..360 and degrades to 72', () {
      int spokes(Object? v) =>
          OrbTuning.fromJson(<String, Object?>{'spokeCount': v}).spokeCount;
      expect(spokes(120), 120);
      expect(spokes(12), 12);
      expect(spokes(360), 360);
      expect(spokes(120.0), 120);
      expect(spokes(4), 12);
      expect(spokes(-5), 12);
      expect(spokes(1000), 360);
      for (final Object? bad in <Object?>[
        null,
        'many',
        true,
        72.5,
        double.nan,
        double.infinity,
        <Object?>[72],
      ]) {
        expect(spokes(bad), 72, reason: '$bad');
      }
    });

    test('dots clamp to 0..24 and degrade per element', () {
      List<int> dots(Object? v) =>
          OrbTuning.fromJson(<String, Object?>{'dots': v}).dots;
      expect(dots(<Object?>[1, 2, 3]), <int>[1, 2, 3]);
      expect(dots(<Object?>[0, 24, 10.0]), <int>[0, 24, 10]);
      expect(dots(<Object?>[-1, 30, 99]), <int>[0, 24, 24]);
      expect(dots(<Object?>['x', 9, null]), <int>[5, 9, 4]);
      expect(dots(<Object?>[2.5, double.nan, 6]), <int>[5, 7, 6]);
      for (final Object? bad in <Object?>[
        null,
        3,
        'dots',
        <Object?>[1, 2],
        <Object?>[1, 2, 3, 4],
        <String, Object?>{'0': 1},
      ]) {
        expect(dots(bad), <int>[5, 7, 4], reason: '$bad');
      }
    });

    test('toJson does not expose the live dots list', () {
      const OrbTuning tuning = OrbTuning.defaults;
      final List<int> dots = tuning.toJson()['dots']! as List<int>;
      dots[0] = 99;
      expect(tuning.dots, <int>[5, 7, 4]);
    });

    test('equality covers spokeCount and dots', () {
      expect(const OrbTuning(spokeCount: 60), isNot(OrbTuning.defaults));
      expect(const OrbTuning(dots: <int>[5, 7, 5]), isNot(OrbTuning.defaults));
      expect(
        const OrbTuning(dots: <int>[5, 7, 4]).hashCode,
        OrbTuning.defaults.hashCode,
      );
    });

    test('anything that is not a map yields the defaults', () {
      for (final Object? bad in <Object?>[null, <Object?>[], 'x', 3]) {
        expect(OrbPreset.fromJson(bad), OrbPreset.defaults, reason: '$bad');
      }
    });

    test('toJson does not expose the live rings list', () {
      final OrbTuning tuning = OrbTuning.defaults;
      final List<double> rings = tuning.toJson()['rings']! as List<double>;
      rings[0] = 99;
      expect(tuning.rings, <double>[1, -2, 2]);
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

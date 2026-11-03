import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The five colours of the orb. Alpha is applied by the painter, so these are
/// opaque `#RRGGBB` values; the defaults are the Console dark palette.
@immutable
class OrbPalette {
  const OrbPalette({
    required this.accent,
    required this.violet,
    required this.pink,
    required this.grid,
    required this.backdrop,
  });

  static const OrbPalette defaults = OrbPalette(
    accent: Color(0xFF59A0F8),
    violet: Color(0xFFAC8BF9),
    pink: Color(0xFFF472B6),
    grid: Color(0xFF35353B),
    backdrop: Color(0xFF1D1D20),
  );

  final Color accent;
  final Color violet;
  final Color pink;
  final Color grid;
  final Color backdrop;

  /// Degrades: a missing or unparsable colour takes its default.
  factory OrbPalette.fromJson(Object? json) {
    final Map<Object?, Object?> m = json is Map
        ? json
        : const <Object?, Object?>{};
    Color pick(String key, Color fallback) => _parseColor(m[key]) ?? fallback;
    return OrbPalette(
      accent: pick('accent', defaults.accent),
      violet: pick('violet', defaults.violet),
      pink: pick('pink', defaults.pink),
      grid: pick('grid', defaults.grid),
      backdrop: pick('backdrop', defaults.backdrop),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'accent': _hex(accent),
    'violet': _hex(violet),
    'pink': _hex(pink),
    'grid': _hex(grid),
    'backdrop': _hex(backdrop),
  };

  static final RegExp _hexColor = RegExp(r'^#[0-9a-fA-F]{6}$');

  static Color? _parseColor(Object? v) {
    if (v is! String || !_hexColor.hasMatch(v)) return null;
    return Color(0xFF000000 | int.parse(v.substring(1), radix: 16));
  }

  static String _hex(Color c) {
    final int rgb = c.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  bool operator ==(Object other) =>
      other is OrbPalette &&
      other.accent == accent &&
      other.violet == violet &&
      other.pink == pink &&
      other.grid == grid &&
      other.backdrop == backdrop;

  @override
  int get hashCode => Object.hash(accent, violet, pink, grid, backdrop);
}

/// Speeds and geometry. Every rate is "cycles per [period]"; time is
/// `t = seconds * speed / period`, never wrapped.
@immutable
class OrbTuning {
  const OrbTuning({
    this.speed = 1,
    this.period = 12,
    this.centerY = 0.44,
    this.radiusScale = 1,
    this.gridStep = 36,
    this.pulse = 3,
    this.spokeFast = 4,
    this.spokeSlow = 2,
    this.rings = const <double>[1, -2, 2],
    this.sweep = 2,
    this.breath = 6,
    this.gridScroll = 12,
  });

  static const OrbTuning defaults = OrbTuning();

  final double speed;
  final double period;

  /// Orb centre as a fraction of the height.
  final double centerY;

  /// Multiplies `min(width, height * 0.88) / 2`.
  final double radiusScale;

  /// Grid cell size in logical pixels.
  final double gridStep;
  final double pulse;
  final double spokeFast;
  final double spokeSlow;

  /// Rotations per period of the three dashed rings, inner to outer. Particles
  /// orbit at twice the ring's rotation, so any integer value closes the loop
  /// after one [period], whatever the particle count.
  final List<double> rings;
  final double sweep;
  final double breath;

  /// Grid cells scrolled per period.
  final double gridScroll;

  /// Degrades: a missing, non-numeric or non-finite value takes its default;
  /// so does a `period` or `gridStep` that is not positive and a `rings`
  /// list that is not exactly three numbers.
  factory OrbTuning.fromJson(Object? json) {
    final Map<Object?, Object?> m = json is Map
        ? json
        : const <Object?, Object?>{};
    double pick(String key, double fallback, {bool positive = false}) {
      final Object? v = m[key];
      if (v is! num || !v.isFinite) return fallback;
      if (positive && v <= 0) return fallback;
      return v.toDouble();
    }

    List<double> rings = defaults.rings;
    final Object? r = m['rings'];
    if (r is List &&
        r.length == 3 &&
        r.every((Object? e) => e is num && e.isFinite)) {
      rings = <double>[for (final Object? e in r) (e! as num).toDouble()];
    }
    return OrbTuning(
      speed: pick('speed', defaults.speed),
      period: pick('period', defaults.period, positive: true),
      centerY: pick('centerY', defaults.centerY),
      radiusScale: pick('radiusScale', defaults.radiusScale),
      gridStep: pick('gridStep', defaults.gridStep, positive: true),
      pulse: pick('pulse', defaults.pulse),
      spokeFast: pick('spokeFast', defaults.spokeFast),
      spokeSlow: pick('spokeSlow', defaults.spokeSlow),
      rings: rings,
      sweep: pick('sweep', defaults.sweep),
      breath: pick('breath', defaults.breath),
      gridScroll: pick('gridScroll', defaults.gridScroll),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'speed': speed,
    'period': period,
    'centerY': centerY,
    'radiusScale': radiusScale,
    'gridStep': gridStep,
    'pulse': pulse,
    'spokeFast': spokeFast,
    'spokeSlow': spokeSlow,
    'rings': rings,
    'sweep': sweep,
    'breath': breath,
    'gridScroll': gridScroll,
  };

  @override
  bool operator ==(Object other) =>
      other is OrbTuning &&
      other.speed == speed &&
      other.period == period &&
      other.centerY == centerY &&
      other.radiusScale == radiusScale &&
      other.gridStep == gridStep &&
      other.pulse == pulse &&
      other.spokeFast == spokeFast &&
      other.spokeSlow == spokeSlow &&
      listEquals(other.rings, rings) &&
      other.sweep == sweep &&
      other.breath == breath &&
      other.gridScroll == gridScroll;

  @override
  int get hashCode => Object.hash(
    speed,
    period,
    centerY,
    radiusScale,
    gridStep,
    pulse,
    spokeFast,
    spokeSlow,
    Object.hashAll(rings),
    sweep,
    breath,
    gridScroll,
  );
}

/// Whole passes of the scene that can be switched off. [core] covers the
/// backdrop glow and the breathing core.
@immutable
class OrbLayers {
  const OrbLayers({
    this.grid = true,
    this.pulses = true,
    this.spokes = true,
    this.rings = true,
    this.sweep = true,
    this.core = true,
  });

  static const OrbLayers defaults = OrbLayers();

  final bool grid;
  final bool pulses;
  final bool spokes;
  final bool rings;
  final bool sweep;
  final bool core;

  factory OrbLayers.fromJson(Object? json) {
    final Map<Object?, Object?> m = json is Map
        ? json
        : const <Object?, Object?>{};
    bool pick(String key) => m[key] is bool ? m[key]! as bool : true;
    return OrbLayers(
      grid: pick('grid'),
      pulses: pick('pulses'),
      spokes: pick('spokes'),
      rings: pick('rings'),
      sweep: pick('sweep'),
      core: pick('core'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'grid': grid,
    'pulses': pulses,
    'spokes': spokes,
    'rings': rings,
    'sweep': sweep,
    'core': core,
  };

  @override
  bool operator ==(Object other) =>
      other is OrbLayers &&
      other.grid == grid &&
      other.pulses == pulses &&
      other.spokes == spokes &&
      other.rings == rings &&
      other.sweep == sweep &&
      other.core == core;

  @override
  int get hashCode => Object.hash(grid, pulses, spokes, rings, sweep, core);
}

/// A whole orb scene description, v1 of the JSON shared with the web port.
@immutable
class OrbPreset {
  const OrbPreset({
    this.palette = OrbPalette.defaults,
    this.tuning = OrbTuning.defaults,
    this.layers = OrbLayers.defaults,
  });

  static const OrbPreset defaults = OrbPreset();
  static const int version = 1;

  final OrbPalette palette;
  final OrbTuning tuning;
  final OrbLayers layers;

  /// Degrade on load, never throw: unknown keys are ignored, missing or bad
  /// values take their defaults, and a missing or unknown `v` is rejected by
  /// returning [defaults] untouched.
  factory OrbPreset.fromJson(Map<String, Object?> json) {
    if (json['v'] != version) return defaults;
    return OrbPreset(
      palette: OrbPalette.fromJson(json['palette']),
      tuning: OrbTuning.fromJson(json['tuning']),
      layers: OrbLayers.fromJson(json['layers']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'palette': palette.toJson(),
    'tuning': tuning.toJson(),
    'layers': layers.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is OrbPreset &&
      other.palette == palette &&
      other.tuning == tuning &&
      other.layers == layers;

  @override
  int get hashCode => Object.hash(palette, tuning, layers);
}

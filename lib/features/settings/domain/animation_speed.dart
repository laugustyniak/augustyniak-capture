/// How fast the processing scene (the orb shown while dictating, transcribing
/// and analysing) moves, as a multiplier on its original speed.
///
/// The original ×1 read as too busy to sit beside a note, so the default is
/// slower; [original] stays one tap away. Pure Dart for the reason
/// [QueueDensity] is: the settings round-trip tests need no binding.
enum AnimationSpeed {
  original(1),
  brisk(0.75),

  /// The default.
  calm(0.5),
  slow(0.35),
  drift(0.2);

  const AnimationSpeed(this.factor);

  /// Multiplies the orb's `OrbTuning.speed`.
  final double factor;

  /// Unknown and absent both answer [calm], so a `settings.json` written by a
  /// newer build that grew a sixth speed still opens.
  static AnimationSpeed fromName(String? name) => AnimationSpeed.values
      .firstWhere((AnimationSpeed s) => s.name == name, orElse: () => calm);

  String get label =>
      '${name.toUpperCase()} ×${factor == factor.roundToDouble() ? factor.toInt() : factor}';
}

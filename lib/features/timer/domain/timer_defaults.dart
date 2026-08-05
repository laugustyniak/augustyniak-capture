/// The session-length rules, in the domain because two layers need them and
/// neither owns them: `AppSettings` defaults and validates a stored value
/// against these, and `FocusTimerController` runs by them.
///
/// Same shape and the same reason as `VaultDefaults` and
/// `EnrichmentProfileDefaults` — a constant that both a persisted type and its
/// controller depend on cannot live in either of them without one importing the
/// other's layer.
class TimerDefaults {
  const TimerDefaults._();

  /// What a fresh install starts with. Long enough for a real block of work
  /// rather than the classic 25, which is the whole reason it is configurable.
  ///
  /// Declared as minutes first because `AppSettings` is a `const` constructor
  /// and persists the length as an integer: `Duration.inMinutes` is a getter,
  /// so it cannot be a `const` default value, while this can.
  static const int defaultMinutes = 40;
  static const Duration duration = Duration(minutes: defaultMinutes);

  /// Offered as chips on the Timer tab. The default sits in the middle of the
  /// list on purpose — it is a starting point, not a floor.
  static const List<int> presetMinutes = <int>[15, 25, 40, 50, 60, 90];

  /// What `+5` adds, both to the configured length and to a live session.
  static const Duration step = Duration(minutes: 5);

  static const Duration min = Duration(minutes: 1);
  static const Duration max = Duration(minutes: 240);

  /// Pulls any value — a chip, a stored integer, a stretched session — into the
  /// supported range instead of rejecting it. A `settings.json` holding a
  /// nonsense length must not be able to produce a timer that cannot run.
  static Duration clamp(Duration value) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

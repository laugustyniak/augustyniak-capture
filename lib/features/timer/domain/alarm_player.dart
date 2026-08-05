import 'alarm_sound.dart';

/// Plays the end-of-session sound.
///
/// A seam of the same shape as `ClipboardSink`: the interface lives in
/// `domain/` so this layer stays free of platform channels and the pure-Dart
/// suites can assert *which* sound a finished session asked for without any
/// audio device existing. `AssetAlarmPlayer` in `data/` is the real one.
abstract interface class AlarmPlayer {
  /// Plays [sound] from the start, cutting off whatever was already playing.
  /// [AlarmSound.none] is a no-op rather than an error.
  Future<void> play(AlarmSound sound);

  /// Silences a ringing alarm — the RESET button, and disposal.
  Future<void> stop();
}

class NoopAlarmPlayer implements AlarmPlayer {
  const NoopAlarmPlayer();

  @override
  Future<void> play(AlarmSound sound) async {}

  @override
  Future<void> stop() async {}
}

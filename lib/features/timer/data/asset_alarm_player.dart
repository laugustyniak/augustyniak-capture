import 'package:audioplayers/audioplayers.dart';

import '../domain/alarm_player.dart';
import '../domain/alarm_sound.dart';

/// The real [AlarmPlayer]: the bundled clip, through `audioplayers`.
///
/// Its own [AudioPlayer], never the one `RecordingsController` uses for capture
/// playback — an alarm firing while a recording is being reviewed must not stop
/// the review, and a review started while the alarm rings must not have to wait
/// for it.
class AssetAlarmPlayer implements AlarmPlayer {
  AssetAlarmPlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(AlarmSound sound) async {
    final String? asset = sound.asset;
    if (asset == null) return;
    // Stopped first so a second session ending while the first alarm is still
    // ringing restarts it rather than layering two copies.
    await _player.stop();
    await _player.play(AssetSource(asset));
  }

  @override
  Future<void> stop() => _player.stop();
}

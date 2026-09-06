import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import 'support/harness.dart';

void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync('audio_playback_test_'),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  test('setPlaybackSpeed updates playbackSpeed and notifies listeners', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
    );
    expect(controller.playbackSpeed, 1.0);

    bool notified = false;
    controller.addListener(() => notified = true);

    await controller.setPlaybackSpeed(1.5);
    expect(controller.playbackSpeed, 1.5);
    expect(notified, isTrue);
  });

  test('seekPlayback updates playbackPosition and notifies listeners', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
    );
    expect(controller.playbackPosition, Duration.zero);

    bool notified = false;
    controller.addListener(() => notified = true);

    await controller.seekPlayback(const Duration(seconds: 12));
    expect(controller.playbackPosition, const Duration(seconds: 12));
    expect(notified, isTrue);
  });

  test('togglePlayback on missing file fails gracefully without crashing', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'missing_audio',
          filePath: '${appDir.path}/nonexistent.m4a',
          type: CaptureType.audioRecording,
        ),
      ],
    );

    await controller.togglePlayback('missing_audio');
    expect(controller.playingId, isNull);
    expect(controller.error, isNotNull);
  });
}

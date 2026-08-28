import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/transcription_limits.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async {
    final File file = File(p.join(directory.path, '$id.$extension'));
    // Stands in for the recorder having written audio: `stopRecording` refuses
    // to index anything it cannot verify is non-empty, so without this the
    // capture would fail for a reason that has nothing to do with the cap.
    await file.writeAsString('audio');
    return file;
  }

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  /// Typed explicitly. `noSuchMethod` answers `Future<dynamic>`, which fails the
  /// cast at the call site — a fine stand-in for a platform throwing on stop,
  /// but not for the ordinary path this group is about.
  @override
  Future<String?> stop() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Fails the way a disconnected input does: the recording is unrecoverable, and
/// the question is whether the controller stays stuck in it.
class _FailingStopRecorder extends _GrantingRecorder {
  @override
  Future<String?> stop() async => throw Exception('input went away');
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Waits for a real-time condition instead of sleeping a fixed span.
///
/// The recording cap is driven by a `Timer.periodic`, so these tests depend on
/// wall-clock scheduling. A fixed sleep encodes an assumption about how busy
/// the machine is, and fails when that assumption is wrong rather than when the
/// behaviour is. Returning as soon as the condition holds keeps an idle run as
/// fast as the sleep was.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('which ceiling binds', () {
    const AudioConfig defaults = AudioConfig();

    test('gpt-4o-transcribe is capped by silent output truncation', () {
      final TranscriptionCeiling? ceiling = TranscriptionLimits.forRequest(
        model: 'gpt-4o-transcribe',
        audio: defaults,
      );

      // Not the 25 MB ceiling (52 min here) and not the 1500 s one: the ceiling
      // that binds is the only one of the three that would have failed quietly.
      expect(ceiling!.limit, TranscriptionLimits.outputTokenCeiling);
      expect(ceiling.reason, contains('2000 output tokens'));
    });

    test('the whole OpenAI transcribe family truncates the same way', () {
      for (final String model in <String>[
        'gpt-4o-mini-transcribe',
        'gpt-4o-transcribe-diarize',
        'GPT-4o-Transcribe',
        // The current generation. Measured on the gpt-4o pair and extended to
        // this one on architecture rather than on a reading — see
        // TranscriptionLimits.truncatesLongOutput for why the cautious
        // direction is the one that ends a recording early.
        'gpt-transcribe',
      ]) {
        expect(
          TranscriptionLimits.forRequest(model: model, audio: defaults)!.limit,
          TranscriptionLimits.outputTokenCeiling,
          reason: '$model belongs to the family that truncates',
        );
      }
    });

    test('whisper-1 is capped only by upload size, and it scales', () {
      // 25 MB at 8 kB/s — nearly an hour, which is the honest answer. Capping
      // whisper-1 at eight minutes would end recordings for a limit it has not
      // got.
      expect(
        TranscriptionLimits.forRequest(
          model: 'whisper-1',
          audio: defaults,
        )!.limit,
        const Duration(seconds: 3125),
      );
      // Double the bitrate, halve the ceiling: the same 25 MB buys half the time.
      expect(
        TranscriptionLimits.forRequest(
          model: 'whisper-1',
          audio: const AudioConfig(bitRate: 128000),
        )!.limit,
        const Duration(seconds: 1562),
      );
    });

    test('an unknown or absent model gets the size ceiling only', () {
      // A local whisper.cpp has no duration limit to speak of, and a model name
      // the app has never heard of must not inherit one on a guess.
      for (final String? model in <String?>[
        null,
        '',
        'whisper-large-v3-turbo',
        // Whisper decodes audio instead of emitting tokens, so no amount of
        // "gpt" in the neighbourhood makes it truncate — this one is on the
        // safe side of a name match that now covers every gpt-*transcribe*.
        'whisper-1',
      ]) {
        expect(
          TranscriptionLimits.forRequest(model: model, audio: defaults)!.limit,
          const Duration(seconds: 3125),
        );
      }
    });

    test('the lowest ceiling wins, whichever it is', () {
      // At 500 kbps the 25 MB budget runs out after 6:40 — before the token
      // ceiling — so size becomes the binding one for the very same model.
      final TranscriptionCeiling? ceiling = TranscriptionLimits.forRequest(
        model: 'gpt-4o-transcribe',
        audio: const AudioConfig(bitRate: 500000),
      );

      expect(ceiling!.limit, const Duration(seconds: 400));
      expect(ceiling.reason, contains('25 MB'));
    });
  });

  group('the cap ends the recording', () {
    late Directory appDir;

    setUp(
      () => appDir = Directory.systemTemp.createTempSync(
        'augustyniak_capture_cap_',
      ),
    );
    tearDown(() => appDir.deleteSync(recursive: true));

    RecordingsController build({AudioRecorder? recorder}) =>
        RecordingsController(
          repository: _FakeRepository(appDir),
          transcriptionService: const DisabledTranscriptionService(),
          recorder: recorder ?? _GrantingRecorder(),
          player: _FakePlayer(),
        );

    test('a running capture is saved when it reaches the limit', () async {
      final RecordingsController controller = build()
        ..recordingLimit = const TranscriptionCeiling(
          Duration(milliseconds: 400),
          'test ceiling',
        );

      await controller.startRecording();
      expect(controller.isRecording, isTrue);

      // The tick that crosses the cap calls the same `stopRecording` the SAVE
      // button does — so the capture is *saved*, not thrown away. Nothing in
      // this app discards a capture, least of all one the app itself ended.
      //
      // Polled rather than slept for a fixed span: the cap is driven by a real
      // 250 ms timer, so on a loaded machine — a parallel test file, a platform
      // build in another terminal — a fixed wait can expire before the crossing
      // tick ever runs, and the test then fails for being early rather than for
      // being wrong. Polling stays fast while the machine is idle.
      await _until(() => !controller.isRecording);

      expect(controller.isRecording, isFalse);
      expect(controller.recordings, hasLength(1));
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('a recorder that throws on stop does not wedge the capture', () async {
      // Regression: the teardown used to sit after the `stop()` await, inside
      // the try. A throw there left `_isRecording` true with the tick still
      // live, so the capture screen never closed — and with a cap set, every
      // tick called back into `stopRecording` for the rest of the session.
      final RecordingsController controller =
          build(recorder: _FailingStopRecorder())
            ..recordingLimit = const TranscriptionCeiling(
              Duration(milliseconds: 400),
              'test ceiling',
            );

      await controller.startRecording();
      await _until(() => !controller.isRecording);

      expect(controller.isRecording, isFalse);
      // The capture itself survives: the file was written as the recording ran,
      // so a throw from `stop()` costs the clean shutdown and nothing else. What
      // this test is about is the teardown — that the tick stopped and the
      // screen closed — and both hold either way.
      expect(controller.recordings, hasLength(1));
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('with no limit set the capture runs on', () async {
      // The desktop answer. Splitting happens before the request there, so no
      // length is unsafe and nothing should interrupt a recording.
      final RecordingsController controller = build();
      expect(controller.recordingLimit, isNull);

      await controller.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(controller.isRecording, isTrue);
      await controller.stopRecording();
      controller.dispose();
    });
  });
}

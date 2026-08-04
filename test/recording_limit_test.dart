import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/settings/domain/audio_config.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';
import 'package:audivoa_core/features/transcription/domain/transcription_limits.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
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

    test('the mini and diarize variants truncate the same way', () {
      for (final String model in <String>[
        'gpt-4o-mini-transcribe',
        'gpt-4o-transcribe-diarize',
        'GPT-4o-Transcribe',
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
      for (final String? model in <String?>[null, '', 'whisper-large-v3-turbo']) {
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

    setUp(() => appDir = Directory.systemTemp.createTempSync('audivoa_cap_'));
    tearDown(() => appDir.deleteSync(recursive: true));

    RecordingsController build() => RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _GrantingRecorder(),
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

      // Two ticks past the cap. The tick that crosses it calls the same
      // `stopRecording` the SAVE button does — the capture is saved, not thrown
      // away, which is the whole contract of this app.
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(controller.isRecording, isFalse);
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

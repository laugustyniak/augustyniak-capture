import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_decoder.dart';
import 'package:augustyniak_capture/features/transcription/data/local_transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/data/whisper_ffi_engine.dart';

/// The one test that exercises the **real** native engine.
///
/// It is skipped unless the three things it needs are actually present, so a
/// machine with no native build — CI, a fresh clone, any platform this slice
/// does not cover — stays green rather than failing for a feature it never
/// built. That makes it a check you have to *opt into* by building, which is
/// the honest shape: nothing here can prove the engine works on a machine that
/// does not have one.
///
///   AUG_WHISPER_LIB    the built libaugustyniak_whisper.so
///   AUG_WHISPER_MODEL  a downloaded ggml model
///   AUG_WHISPER_AUDIO  a real capture (.m4a) to transcribe
void main() {
  final String? libraryPath = Platform.environment['AUG_WHISPER_LIB'];
  final String? modelPath = Platform.environment['AUG_WHISPER_MODEL'];
  final String? audioPath = Platform.environment['AUG_WHISPER_AUDIO'];

  final bool ready =
      libraryPath != null &&
      modelPath != null &&
      audioPath != null &&
      File(libraryPath).existsSync() &&
      File(modelPath).existsSync() &&
      File(audioPath).existsSync();

  group('the native engine, end to end', () {
    test('transcribes a real capture with no network involved', () async {
      final WhisperFfiEngine engine = WhisperFfiEngine(
        decoder: const FfmpegAudioDecoder(),
        libraryPath: libraryPath!,
      );
      expect(
        engine.isAvailable,
        isTrue,
        reason: engine.unavailableReason ?? 'engine reported unavailable',
      );

      // Through `LocalTranscriptionService`, not the engine alone: that is the
      // object the drain loop actually reaches, and it owns the model lookup
      // and the missing-file refusals this has to keep working.
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: engine,
        modelId: 'tiny-q5_1',
        modelPath: (String _) async => modelPath!,
        language: 'en',
      );

      final String text = await service.transcribe(File(audioPath!));

      expect(text, isNotEmpty);
      expect(
        text.toLowerCase(),
        contains('country'),
        reason: 'the sample is the JFK line; this is real recognition',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a model that is gone is reported, not guessed at', () async {
      final LocalTranscriptionService service = LocalTranscriptionService(
        engine: WhisperFfiEngine(
          decoder: const FfmpegAudioDecoder(),
          libraryPath: libraryPath!,
        ),
        modelId: 'tiny-q5_1',
        modelPath: (String _) async => null,
      );

      await expectLater(
        service.transcribe(File(audioPath!)),
        throwsA(isA<Exception>()),
      );
    });
  }, skip: ready ? false : 'native engine artifacts not present');
}

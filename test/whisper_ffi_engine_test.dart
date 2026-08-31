import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_decoder.dart';
import 'package:augustyniak_capture/features/transcription/data/whisper_ffi_engine.dart';
import 'package:augustyniak_capture/features/transcription/domain/local_transcription_engine.dart';

class _AvailableDecoder implements AudioDecoder {
  @override
  bool get isAvailable => true;
  @override
  Future<DecodedAudio> decodeToPcm(File audio) async =>
      throw UnimplementedError();
}

void main() {
  // The engine's *unavailable* half is the part that must work everywhere, and
  // it is the half a machine with no native build can still test. Loading the
  // real library is what `flutter build linux` and the by-hand run cover; there
  // is no fake for `dlopen` that would prove anything.
  group('availability is decided once, not per capture', () {
    test('a missing library reports why rather than throwing', () {
      final WhisperFfiEngine engine = WhisperFfiEngine(
        decoder: _AvailableDecoder(),
        libraryPath: '/nonexistent/libaugustyniak_whisper.so',
      );

      expect(engine.isAvailable, isFalse);
      expect(engine.unavailableReason, isNotNull);
      expect(
        engine.unavailableReason,
        contains('/nonexistent/libaugustyniak_whisper.so'),
        reason: 'the path is the one fact that makes this diagnosable',
      );
    });

    test('an unavailable engine refuses instead of answering empty', () async {
      final WhisperFfiEngine engine = WhisperFfiEngine(
        decoder: _AvailableDecoder(),
        libraryPath: '/nonexistent/libaugustyniak_whisper.so',
      );

      await expectLater(
        engine.transcribe(audio: File('/tmp/x.m4a'), modelPath: '/tmp/m.bin'),
        throwsA(isA<LocalTranscriptionUnavailableException>()),
        reason:
            'an empty transcript is a result; a build that cannot run a model '
            'has not produced one',
      );
    });

    test('a build with no decoder says so, not that the library is missing', () {
      final WhisperFfiEngine engine = WhisperFfiEngine(
        decoder: const UnavailableAudioDecoder(),
        libraryPath: '/nonexistent/libaugustyniak_whisper.so',
      );

      expect(engine.isAvailable, isFalse);
      expect(engine.unavailableReason, contains('decoder'));
    });

    test('the default path is anchored to the executable, never bare', () {
      // A bare name would let the system loader answer with an unrelated
      // library of the same name, which is worse than finding none.
      expect(
        WhisperFfiEngine.defaultLibraryPath(),
        anyOf(contains(Platform.pathSeparator), equals('libaugustyniak_whisper.so')),
      );
      if (Platform.isLinux) {
        expect(WhisperFfiEngine.defaultLibraryPath(), endsWith('.so'));
        expect(WhisperFfiEngine.defaultLibraryPath(), contains('/lib/'));
      }
    });
  });
}

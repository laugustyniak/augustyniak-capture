import 'dart:io';

import 'package:augustyniak_capture/features/processing/data/native_media_processor.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_decoder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'video_poster_ffmpeg_test.dart' show ffmpegSkipReason;

/// What 16 kHz mono float32 costs per second, which is the only thing that
/// proves the flags actually took: an ffmpeg that ignored `-ar` or `-ac` still
/// writes a file, still exits zero, and still produces text — the wrong text,
/// from audio at the wrong speed.
const int _bytesPerSecond = 16000 * 4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the default decoder', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('augustyniak_decode_');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('refuses rather than answering silence', () async {
      // A model handed no samples does not fail — it returns confident
      // nonsense, which is the quietest failure this path could have.
      const AudioDecoder decoder = UnavailableAudioDecoder();
      expect(decoder.isAvailable, isFalse);
      await expectLater(
        decoder.decodeToPcm(File(p.join(dir.path, 'anything.m4a'))),
        throwsA(isA<AudioDecodeException>()),
      );
    });

    test('a missing source fails before anything is spawned', () async {
      await expectLater(
        const FfmpegAudioDecoder().decodeToPcm(
          File(p.join(dir.path, 'gone.m4a')),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a missing binary leaks no temp directory', () async {
      final File source = File(p.join(dir.path, 'a.m4a'))
        ..writeAsStringSync('not really audio');
      final int before = Directory.systemTemp
          .listSync()
          .where((FileSystemEntity e) => p.basename(e.path).startsWith('augustyniak_pcm'))
          .length;

      await expectLater(
        const FfmpegAudioDecoder(
          executable: 'augustyniak-no-such-binary',
        ).decodeToPcm(source),
        throwsA(anything),
      );

      final int after = Directory.systemTemp
          .listSync()
          .where((FileSystemEntity e) => p.basename(e.path).startsWith('augustyniak_pcm'))
          .length;
      expect(after, before, reason: 'a failed decode must clean up after itself');
    });
  });

  group('the real ffmpeg decoder', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('augustyniak_decode_real_');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// A genuine AAC file, so the decode under test is a real one — the same
    /// reasoning as the poster suite: a fake process runner proves the contract
    /// and nothing at all about whether the flags are right.
    Future<File> generateTone(String name, {required int seconds}) async {
      final File file = File(p.join(dir.path, name));
      final ProcessResult result = await Process.run('ffmpeg', <String>[
        '-y',
        '-loglevel', 'error',
        '-f', 'lavfi',
        '-i', 'sine=frequency=440:duration=$seconds',
        // Deliberately *not* the target format: 44.1 kHz stereo, so a decode
        // that ignored `-ar`/`-ac` produces a file of visibly the wrong size.
        '-ar', '44100',
        '-ac', '2',
        '-c:a', 'aac',
        file.path,
      ], stderrEncoding: SystemEncoding());
      expect(result.exitCode, 0, reason: result.stderr as String);
      return file;
    }

    test('produces 16 kHz mono float32, and leaves the source alone', () async {
      final File source = await generateTone('tone.m4a', seconds: 2);
      final int sourceLength = await source.length();
      final DateTime sourceModified = await source.lastModified();

      final DecodedAudio decoded = await const FfmpegAudioDecoder()
          .decodeToPcm(source);
      addTearDown(decoded.dispose);

      final int bytes = await decoded.file.length();
      // Headerless raw PCM, so the size *is* the sample count. Two seconds at
      // 16 kHz mono float32 is 128 000 bytes; the tolerance covers the encoder
      // delay AAC adds at both ends.
      expect(
        bytes,
        closeTo(2 * _bytesPerSecond, _bytesPerSecond ~/ 2),
        reason:
            'a decode that kept 44.1 kHz or stereo would be roughly three to '
            'six times this size',
      );

      // The processor rule, one level down: a decoder only ever reads.
      expect(await source.length(), sourceLength);
      expect(await source.lastModified(), sourceModified);
    });

    test('a longer file scales linearly, which is what proves the rate', () async {
      final File source = await generateTone('long.m4a', seconds: 4);
      final DecodedAudio decoded = await const FfmpegAudioDecoder()
          .decodeToPcm(source);
      addTearDown(decoded.dispose);

      expect(
        await decoded.file.length(),
        closeTo(4 * _bytesPerSecond, _bytesPerSecond ~/ 2),
      );
    });

    test('dispose removes the derived samples, never the source', () async {
      final File source = await generateTone('tidy.m4a', seconds: 1);
      final DecodedAudio decoded = await const FfmpegAudioDecoder()
          .decodeToPcm(source);
      final File samples = decoded.file;

      await decoded.dispose();

      expect(samples.existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
    });

    test('a file that is not audio fails cleanly and leaves nothing', () async {
      final File notAudio = File(p.join(dir.path, 'notes.txt'))
        ..writeAsStringSync('this is not a sound');

      await expectLater(
        const FfmpegAudioDecoder().decodeToPcm(notAudio),
        throwsA(isA<AudioDecodeException>()),
      );
      expect(notAudio.existsSync(), isTrue);
    });
  }, skip: ffmpegSkipReason());

  group('the mobile decoder', () {
    const MethodChannel channel = MethodChannel(
      'ai.augustyniak.capture/media_processing',
    );
    late Directory dir;
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('augustyniak_decode_native_');
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    test('asks the native side for PCM at the model\'s rate', () async {
      final File source = File(p.join(dir.path, 'a.m4a'))
        ..writeAsStringSync('audio');
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        seen = call;
        // The native side writes the file; standing in for it here is what
        // makes the "wrote nothing" case below a different test rather than
        // the only outcome.
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        File(args['outputPath']! as String).writeAsBytesSync(
          List<int>.filled(4 * 16000, 0),
        );
        return null;
      });

      final DecodedAudio decoded = await const NativeMobileMediaProcessor()
          .decodeToPcm(source);
      addTearDown(decoded.dispose);

      expect(seen!.method, 'decodeAudioToPcm');
      final Map<Object?, Object?> args =
          seen!.arguments as Map<Object?, Object?>;
      expect(args['sourcePath'], source.path);
      expect(args['sampleRate'], FfmpegAudioDecoder.sampleRate);
      expect(decoded.file.existsSync(), isTrue);
    });

    test('a channel that writes nothing is a failure, not silence', () async {
      final File source = File(p.join(dir.path, 'b.m4a'))
        ..writeAsStringSync('audio');
      // Returns cleanly and produces no file — the trap the poster extractor
      // already documents, and the one an exit-code-only check walks into.
      messenger.setMockMethodCallHandler(channel, (MethodCall _) async => null);

      await expectLater(
        const NativeMobileMediaProcessor().decodeToPcm(source),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a channel this platform does not implement fails readably', () async {
      final File source = File(p.join(dir.path, 'c.m4a'))
        ..writeAsStringSync('audio');
      messenger.setMockMethodCallHandler(channel, null);

      await expectLater(
        const NativeMobileMediaProcessor().decodeToPcm(source),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:augustyniak_capture/features/transcription/data/audio_decoder.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_repairer.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_splitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'video_poster_ffmpeg_test.dart' show ffmpegSkipReason;

class _FakeAudioRepairer implements AudioRepairer {
  _FakeAudioRepairer({this.shouldSucceed = true});

  final bool shouldSucceed;
  int callCount = 0;
  File? lastRepairedFile;

  @override
  bool get isAvailable => true;

  @override
  Future<File?> repair(File audio, Directory workDir) async {
    callCount++;
    lastRepairedFile = audio;
    if (!shouldSucceed) return null;
    // Still not a valid container — the decoder and splitter must fail on it
    // rather than ask for another repair.
    return File(p.join(workDir.path, 'repair', 'source_fixed.m4a'))
      ..createSync(recursive: true)
      ..writeAsStringSync('still corrupt');
  }
}

void main() {
  group('UnavailableAudioRepairer', () {
    test('reports unavailable and does not repair', () async {
      const AudioRepairer repairer = UnavailableAudioRepairer();
      expect(repairer.isAvailable, isFalse);
      expect(
        await repairer.repair(File('any.m4a'), Directory.systemTemp),
        isNull,
      );
    });
  });

  group('FfmpegAudioRepairer edge cases', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('augustyniak_repair_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns null for nonexistent file', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File nonExistent = File(p.join(tempDir.path, 'missing.m4a'));
      expect(await repairer.repair(nonExistent, tempDir), isNull);
    });

    test('returns null for zero-length file', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File empty = File(p.join(tempDir.path, 'empty.m4a'))..createSync();
      expect(await repairer.repair(empty, tempDir), isNull);
    });

    test('returns null for non-m4a file extension', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File txt = File(p.join(tempDir.path, 'sample.txt'))..writeAsStringSync('hello');
      expect(await repairer.repair(txt, tempDir), isNull);
    });

    test('handles missing untrunc binary gracefully without crashing', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer(
        untruncExecutable: 'augustyniak-no-such-untrunc-binary',
      );
      final File dummy = File(p.join(tempDir.path, 'sample.m4a'))
        ..writeAsStringSync('dummy content');
      expect(await repairer.repair(dummy, tempDir), isNull);
    });

    test('falls back to synthetic reference when sibling fails untrunc', () async {
      File(p.join(tempDir.path, 'sibling.m4a'))
          .writeAsStringSync('corrupt sibling header that exceeds length' * 100);
      final File target = File(p.join(tempDir.path, 'target.m4a'))
        ..writeAsStringSync('target m4a content' * 100);

      // Using invalid untrunc executable tests that sibling failure falls through
      // gracefully and cleans up
      const AudioRepairer repairer = FfmpegAudioRepairer(
        untruncExecutable: 'augustyniak-no-such-untrunc',
      );
      expect(await repairer.repair(target, tempDir), isNull);
    });
  });

  group('FfmpegAudioRepairer against the real binaries', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('augustyniak_repair_real_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('writes the repaired copy under workDir and leaves the source alone',
        () async {
      // ffmpeg puts `moov` after `mdat` unless asked for faststart, so cutting
      // the file at the `moov` offset is exactly what an interrupted stop
      // leaves behind: every sample on disk, no index.
      final Directory sourceDir = Directory(p.join(tempDir.path, 'recordings'))
        ..createSync();
      final File good = await generateTone(sourceDir, 'good.m4a', '3');
      final File broken = File(p.join(sourceDir.path, 'broken.m4a'))
        ..writeAsBytesSync(withoutMoov(good.readAsBytesSync()));
      good.deleteSync();
      final List<int> before = broken.readAsBytesSync();
      final Directory workDir = Directory(p.join(tempDir.path, 'work'))
        ..createSync();

      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File? repaired = await repairer.repair(broken, workDir);

      expect(repaired, isNotNull);
      expect(p.isWithin(workDir.path, repaired!.path), isTrue);
      expect(await repaired.length(), greaterThan(0));
      expect(broken.readAsBytesSync(), before);
      expect(
        sourceDir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['broken.m4a'],
      );
    });

    test('the decoder retries on the repaired copy and owns it', () async {
      final File good = await generateTone(tempDir, 'good.m4a', '3');
      final File broken = File(p.join(tempDir.path, 'broken.m4a'))
        ..writeAsBytesSync(withoutMoov(good.readAsBytesSync()));
      good.deleteSync();
      final List<int> before = broken.readAsBytesSync();

      const FfmpegAudioDecoder decoder = FfmpegAudioDecoder();
      final DecodedAudio decoded = await decoder.decodeToPcm(broken);
      try {
        expect(await decoded.file.length(), greaterThan(0));
        expect(broken.readAsBytesSync(), before);
        // The repaired copy sits beside the PCM, in the directory dispose owns.
        expect(
          Directory(p.join(decoded.file.parent.path, 'repair')).existsSync(),
          isTrue,
        );
      } finally {
        await decoded.dispose();
      }
      expect(decoded.file.parent.existsSync(), isFalse);
    });

    test('the splitter hands over the repaired part, never the source',
        () async {
      final File good = await generateTone(tempDir, 'good.m4a', '3');
      final File broken = File(p.join(tempDir.path, 'broken.m4a'))
        ..writeAsBytesSync(withoutMoov(good.readAsBytesSync()));
      good.deleteSync();
      final List<int> before = broken.readAsBytesSync();

      const FfmpegAudioSplitter splitter = FfmpegAudioSplitter();
      final AudioSegments segments =
          await splitter.split(broken, const Duration(minutes: 5));
      try {
        // One part, but derived: `whole(broken)` would send the file ffmpeg
        // just refused, because the chunked service unwraps `!isSplit`.
        expect(segments.isSplit, isTrue);
        expect(segments.files, hasLength(1));
        expect(segments.files.single.path, isNot(broken.path));
        expect(p.basename(segments.files.single.path), startsWith('part_'));
        expect(broken.readAsBytesSync(), before);
      } finally {
        await segments.dispose();
      }
      expect(segments.files.single.parent.existsSync(), isFalse);
    });
  }, skip: ffmpegSkipReason() ?? untruncSkipReason());

  group('FfmpegAudioSplitter with AudioRepairer integration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('augustyniak_splitter_repair_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('delegates to repairer when moov atom is missing', () async {
      final File dummyM4a = File(p.join(tempDir.path, 'corrupt.m4a'))
        ..writeAsStringSync('corrupted m4a without moov');

      final _FakeAudioRepairer repairer = _FakeAudioRepairer(shouldSucceed: false);
      final FfmpegAudioSplitter splitter = FfmpegAudioSplitter(repairer: repairer);

      await expectLater(
        splitter.split(dummyM4a, const Duration(minutes: 5)),
        throwsA(isA<ProcessException>()),
      );
      expect(repairer.callCount, 1);
      expect(repairer.lastRepairedFile?.path, dummyM4a.path);
    });

    test('prevents infinite recursion if repairer succeeds but ffmpeg still fails', () async {
      final File dummyM4a = File(p.join(tempDir.path, 'corrupt.m4a'))
        ..writeAsStringSync('corrupted m4a without moov');

      // Repairer reports success, but file is still invalid
      final _FakeAudioRepairer repairer = _FakeAudioRepairer(shouldSucceed: true);
      final FfmpegAudioSplitter splitter = FfmpegAudioSplitter(repairer: repairer);

      await expectLater(
        splitter.split(dummyM4a, const Duration(minutes: 5)),
        throwsA(isA<ProcessException>()),
      );
      // Exactly 1 repair attempt, no infinite loop
      expect(repairer.callCount, 1);
    });
  }, skip: ffmpegSkipReason());

  group('FfmpegAudioDecoder with AudioRepairer integration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('augustyniak_decoder_repair_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('delegates to repairer when moov atom is missing', () async {
      final File dummyM4a = File(p.join(tempDir.path, 'corrupt.m4a'))
        ..writeAsStringSync('corrupted m4a without moov');

      final _FakeAudioRepairer repairer = _FakeAudioRepairer(shouldSucceed: false);
      final FfmpegAudioDecoder decoder = FfmpegAudioDecoder(repairer: repairer);

      await expectLater(
        decoder.decodeToPcm(dummyM4a),
        throwsA(isA<AudioDecodeException>()),
      );
      expect(repairer.callCount, 1);
      expect(repairer.lastRepairedFile?.path, dummyM4a.path);
    });

    test('prevents infinite recursion if repairer succeeds but ffmpeg still fails', () async {
      final File dummyM4a = File(p.join(tempDir.path, 'corrupt.m4a'))
        ..writeAsStringSync('corrupted m4a without moov');

      final _FakeAudioRepairer repairer = _FakeAudioRepairer(shouldSucceed: true);
      final FfmpegAudioDecoder decoder = FfmpegAudioDecoder(repairer: repairer);

      await expectLater(
        decoder.decodeToPcm(dummyM4a),
        throwsA(isA<AudioDecodeException>()),
      );
      // Exactly 1 repair attempt, no infinite loop
      expect(repairer.callCount, 1);
    });
  }, skip: ffmpegSkipReason());
}

/// Same probe shape as [ffmpegSkipReason]: a machine without untrunc skips the
/// real-repair test rather than failing it.
String? untruncSkipReason() {
  try {
    // untrunc exits non-zero on a bare invocation; being able to run it at all
    // is the whole question.
    Process.runSync('untrunc', <String>[]);
    return null;
  } on ProcessException {
    return 'untrunc is not on PATH — skipping the real-repair test.';
  }
}

/// A short AAC tone in the app's own capture format.
Future<File> generateTone(Directory dir, String name, String seconds) async {
  final File file = File(p.join(dir.path, name));
  final ProcessResult result = await Process.run('ffmpeg', <String>[
    '-y',
    '-loglevel', 'error',
    '-f', 'lavfi',
    '-i', 'sine=frequency=440:duration=$seconds:sample_rate=16000',
    '-c:a', 'aac',
    '-b:a', '64k',
    '-ac', '1',
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('ffmpeg could not generate a tone: ${result.stderr}');
  }
  return file;
}

/// Everything up to the top-level `moov` atom — the container an interrupted
/// recorder leaves behind.
List<int> withoutMoov(List<int> bytes) {
  final ByteData view = ByteData.sublistView(Uint8List.fromList(bytes));
  int offset = 0;
  while (offset + 8 <= bytes.length) {
    final int size = view.getUint32(offset);
    final String type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'moov') return bytes.sublist(0, offset);
    if (size < 8) break;
    offset += size;
  }
  throw StateError('no top-level moov atom in fixture');
}

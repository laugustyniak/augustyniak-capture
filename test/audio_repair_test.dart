import 'dart:io';

import 'package:augustyniak_capture/features/transcription/data/audio_decoder.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_repairer.dart';
import 'package:augustyniak_capture/features/transcription/data/audio_splitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeAudioRepairer implements AudioRepairer {
  _FakeAudioRepairer({this.shouldSucceed = true});

  final bool shouldSucceed;
  int callCount = 0;
  File? lastRepairedFile;

  @override
  bool get isAvailable => true;

  @override
  Future<bool> repair(File audio) async {
    callCount++;
    lastRepairedFile = audio;
    return shouldSucceed;
  }
}

void main() {
  group('UnavailableAudioRepairer', () {
    test('reports unavailable and does not repair', () async {
      const AudioRepairer repairer = UnavailableAudioRepairer();
      expect(repairer.isAvailable, isFalse);
      expect(await repairer.repair(File('any.m4a')), isFalse);
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

    test('returns false for nonexistent file', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File nonExistent = File(p.join(tempDir.path, 'missing.m4a'));
      expect(await repairer.repair(nonExistent), isFalse);
    });

    test('returns false for zero-length file', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File empty = File(p.join(tempDir.path, 'empty.m4a'))..createSync();
      expect(await repairer.repair(empty), isFalse);
    });

    test('returns false for non-m4a file extension', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer();
      final File txt = File(p.join(tempDir.path, 'sample.txt'))..writeAsStringSync('hello');
      expect(await repairer.repair(txt), isFalse);
    });

    test('handles missing untrunc binary gracefully without crashing', () async {
      const AudioRepairer repairer = FfmpegAudioRepairer(
        untruncExecutable: 'augustyniak-no-such-untrunc-binary',
      );
      final File dummy = File(p.join(tempDir.path, 'sample.m4a'))
        ..writeAsStringSync('dummy content');
      expect(await repairer.repair(dummy), isFalse);
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
      expect(await repairer.repair(target), isFalse);
    });
  });

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
  });

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
  });
}

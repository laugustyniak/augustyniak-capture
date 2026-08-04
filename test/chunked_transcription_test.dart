import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/transcription/data/audio_splitter.dart';
import 'package:augustyniak_capture/features/transcription/data/chunked_transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

/// Records what it was handed, so a test can assert the decorator sent the parts
/// rather than the whole file — and in which order.
class _RecordingService implements TranscriptionService {
  _RecordingService({this.failOn});

  final List<String> received = <String>[];

  /// Basename that should throw, standing in for a part the endpoint rejects.
  final String? failOn;

  @override
  Future<String> transcribe(File audioFile) async {
    final String name = p.basename(audioFile.path);
    received.add(name);
    if (name == failOn) throw const HttpException('boom');
    return 'text of $name';
  }
}

/// Splits into [count] real files inside a temp directory it hands over, so the
/// decorator's cleanup can be asserted against the filesystem.
class _CountingSplitter implements AudioSplitter {
  _CountingSplitter(this.count);

  final int count;
  Directory? tempDir;

  @override
  bool get isAvailable => true;

  @override
  Future<AudioSegments> split(File audio, Duration maxSegment) async {
    if (count <= 1) return AudioSegments.whole(audio);

    final Directory dir = await Directory.systemTemp.createTemp('audivoa_seg_');
    tempDir = dir;
    final List<File> parts = <File>[];
    for (int index = 0; index < count; index++) {
      final File part = File(
        p.join(dir.path, 'part_${index.toString().padLeft(5, '0')}.m4a'),
      );
      await part.writeAsString('audio $index');
      parts.add(part);
    }
    return AudioSegments.parts(parts, dir);
  }
}

void main() {
  late Directory appDir;
  late File source;

  setUp(() async {
    appDir = Directory.systemTemp.createTempSync('audivoa_chunk_');
    source = File(p.join(appDir.path, 'capture.m4a'));
    await source.writeAsString('whole recording');
  });
  tearDown(() => appDir.deleteSync(recursive: true));

  test('a short capture is sent as itself, unwrapped', () async {
    // The common case, and the one that must stay byte-identical to the
    // behaviour that shipped before splitting existed: one request, and the
    // caller's own file — not a copy of it.
    final _RecordingService inner = _RecordingService();
    final ChunkedTranscriptionService service = ChunkedTranscriptionService(
      inner,
      _CountingSplitter(1),
    );

    expect(await service.transcribe(source), 'text of capture.m4a');
    expect(inner.received, <String>['capture.m4a']);
  });

  test('where nothing can be split, the whole file still goes', () async {
    // Mobile. The decorator is wired there too, and has to be a pass-through
    // rather than a failure — the recording-length cap is what protects that
    // platform, not this.
    final _RecordingService inner = _RecordingService();
    final ChunkedTranscriptionService service = ChunkedTranscriptionService(
      inner,
      const UnavailableAudioSplitter(),
    );

    expect(await service.transcribe(source), 'text of capture.m4a');
    expect(inner.received, <String>['capture.m4a']);
  });

  test('a long capture is sent in parts and joined in order', () async {
    final _RecordingService inner = _RecordingService();
    final _CountingSplitter splitter = _CountingSplitter(4);
    final ChunkedTranscriptionService service = ChunkedTranscriptionService(
      inner,
      splitter,
    );

    final String text = await service.transcribe(source);

    // Order is the loop order, which is the segment order — the property the
    // sequential send exists to guarantee.
    expect(inner.received, <String>[
      'part_00000.m4a',
      'part_00001.m4a',
      'part_00002.m4a',
      'part_00003.m4a',
    ]);
    expect(
      text,
      'text of part_00000.m4a text of part_00001.m4a '
      'text of part_00002.m4a text of part_00003.m4a',
    );
    // The source is only ever read — the processor rule, one level down.
    expect(await source.exists(), isTrue);
    expect(await splitter.tempDir!.exists(), isFalse);
  });

  test('a failing part fails the job and still cleans up', () async {
    // The existing contract: the controller marks the item `failed`, the source
    // stays on disk, and retry re-runs it. What must not survive is the temp
    // directory — a failure every five minutes would otherwise fill the disk.
    final _RecordingService inner = _RecordingService(
      failOn: 'part_00001.m4a',
    );
    final _CountingSplitter splitter = _CountingSplitter(3);
    final ChunkedTranscriptionService service = ChunkedTranscriptionService(
      inner,
      splitter,
    );

    await expectLater(
      service.transcribe(source),
      throwsA(isA<HttpException>()),
    );

    // Stopped at the failing part rather than pressing on with a gap in the
    // middle of the transcript.
    expect(inner.received, <String>['part_00000.m4a', 'part_00001.m4a']);
    expect(await splitter.tempDir!.exists(), isFalse);
    expect(await source.exists(), isTrue);
  });

  test('a blank part does not leave a double space in the join', () async {
    final ChunkedTranscriptionService service = ChunkedTranscriptionService(
      _BlankMiddleService(),
      _CountingSplitter(3),
    );

    expect(await service.transcribe(source), 'first last');
  });
}

/// Answers with nothing for the middle part — a genuinely silent stretch of
/// audio, which providers do return an empty string for.
class _BlankMiddleService implements TranscriptionService {
  int _calls = 0;

  @override
  Future<String> transcribe(File audioFile) async {
    _calls++;
    if (_calls == 1) return 'first';
    if (_calls == 2) return '   ';
    return 'last';
  }
}

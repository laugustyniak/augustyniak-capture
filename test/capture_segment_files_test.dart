import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';

void main() {
  late Directory dir;
  late RecordingsRepository repository;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('segment-files');
    repository = RecordingsRepository(directoryProvider: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Recording twoSegments() {
    final DateTime at = DateTime.utc(2026, 8, 28);
    return Recording(
      id: 'abc',
      filePath: p.join(dir.path, 'abc.m4a'),
      createdAt: at,
      durationMs: 1000,
      sizeBytes: 10,
      status: RecordingStatus.completed,
      type: CaptureType.audioRecording,
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: p.join(dir.path, 'abc.m4a'),
          type: CaptureType.audioRecording,
          createdAt: at,
          sizeBytes: 10,
        ),
        CaptureSegment(
          index: 1,
          filePath: p.join(dir.path, 'abc-1.m4a'),
          type: CaptureType.audioRecording,
          createdAt: at,
          sizeBytes: 10,
        ),
      ],
    );
  }

  test('segment 0 keeps the plain name, later ones are suffixed', () async {
    expect(
      p.basename((await repository.createSegmentFile('abc', 0, 'm4a')).path),
      'abc.m4a',
    );
    expect(
      p.basename((await repository.createSegmentFile('abc', 2, 'txt')).path),
      'abc-2.txt',
    );
  });

  test('deleteArtifacts removes every segment and the poster', () async {
    await File(p.join(dir.path, 'abc.m4a')).writeAsString('one');
    await File(p.join(dir.path, 'abc-1.m4a')).writeAsString('two');
    await File(p.join(dir.path, 'abc.thumb.jpg')).writeAsString('poster');

    await repository.deleteArtifacts(twoSegments());

    expect(await File(p.join(dir.path, 'abc.m4a')).exists(), isFalse);
    expect(await File(p.join(dir.path, 'abc-1.m4a')).exists(), isFalse);
    expect(await File(p.join(dir.path, 'abc.thumb.jpg')).exists(), isFalse);
  });

  test('findOrphans does not re-adopt an indexed segment file', () async {
    await File(p.join(dir.path, 'abc.m4a')).writeAsString('one');
    await File(p.join(dir.path, 'abc-1.m4a')).writeAsString('two');

    final List<Recording> orphans = await repository.findOrphans(
      <Recording>[twoSegments()],
    );

    expect(orphans, isEmpty);
  });

  test('a segment file whose row is gone is still recovered', () async {
    await File(p.join(dir.path, 'lost-1.m4a')).writeAsString('two');

    final List<Recording> orphans = await repository.findOrphans(<Recording>[]);

    expect(orphans, hasLength(1));
    expect(orphans.single.id, 'lost-1');
  });
}

import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late RecordingsRepository repository;
  final DateTime now = DateTime.utc(2026, 10, 15, 12);
  final int nowMs = now.millisecondsSinceEpoch;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recordings-trash');
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
        for (final (int i, String name) in <String>[
          'abc.m4a',
          'abc-1.m4a',
        ].indexed)
          CaptureSegment(
            index: i,
            filePath: p.join(dir.path, name),
            type: CaptureType.audioRecording,
            createdAt: at,
            sizeBytes: 10,
          ),
      ],
    );
  }

  File write(String name, {Directory? into}) {
    final File file = File(p.join((into ?? dir).path, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    return file;
  }

  Directory trash() => Directory(p.join(dir.path, '.trash'));

  List<String> trashed() => trash().existsSync()
      ? (trash()
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort())
      : <String>[];

  group('trashArtifacts', () {
    test(
      'moves every artifact into .trash with the timestamp prefix',
      () async {
        write('abc.m4a');
        write('abc-1.m4a');
        write('abc.thumb.jpg');

        await repository.trashArtifacts(twoSegments(), held: false, now: now);

        expect(trashed(), <String>[
          '$nowMs-abc-1.m4a',
          '$nowMs-abc.m4a',
          '$nowMs-abc.thumb.jpg',
        ]);
        expect(File(p.join(dir.path, 'abc.m4a')).existsSync(), isFalse);
        expect(File(p.join(dir.path, 'abc-1.m4a')).existsSync(), isFalse);
        expect(File(p.join(dir.path, 'abc.thumb.jpg')).existsSync(), isFalse);
        expect(
          File(p.join(trash().path, '$nowMs-abc.m4a')).readAsBytesSync(),
          <int>[1, 2, 3],
        );
      },
    );

    test('skips an artifact that is already missing', () async {
      write('abc.m4a');

      await repository.trashArtifacts(twoSegments(), held: false, now: now);

      expect(trashed(), <String>['$nowMs-abc.m4a']);
    });

    test('held entries carry the held- prefix', () async {
      write('abc.m4a');

      await repository.trashArtifacts(twoSegments(), held: true, now: now);

      expect(trashed(), <String>['held-$nowMs-abc.m4a']);
      expect(await repository.heldTrashCount(), 1);
    });

    test('a failing artifact puts the moved ones back and rethrows', () async {
      write('abc.m4a');
      write('abc-1.m4a');
      // A directory sits where segment 1 would be trashed: rename onto it and
      // the copy fallback both fail.
      Directory(p.join(trash().path, '$nowMs-abc-1.m4a'))
          .createSync(recursive: true);

      await expectLater(
        repository.trashArtifacts(twoSegments(), held: false, now: now),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(dir.path, 'abc.m4a')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'abc-1.m4a')).existsSync(), isTrue);
      expect(
        trash().listSync().whereType<File>(),
        isEmpty,
        reason: 'nothing may be left in .trash for a row that is kept',
      );
    });

    test('a copy-moved file is copied back when a later artifact fails', () async {
      // `rename` refuses, as it does across filesystems, so segment 0 travels
      // by copy-then-delete; segment 1 then finds a directory in its way. The
      // rollback must not try `rename` again — that is what failed.
      final RecordingsRepository copying = RecordingsRepository(
        directoryProvider: () async => dir,
        renameFile: (File source, String target) =>
            throw const FileSystemException('EXDEV', 'cross-device'),
      );
      write('abc.m4a');
      write('abc-1.m4a');
      Directory(p.join(trash().path, '$nowMs-abc-1.m4a'))
          .createSync(recursive: true);

      await expectLater(
        copying.trashArtifacts(twoSegments(), held: false, now: now),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(dir.path, 'abc.m4a')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'abc-1.m4a')).existsSync(), isTrue);
      expect(trash().listSync().whereType<File>(), isEmpty);
    });

    test('a copy whose source will not delete leaves no second copy', () async {
      // Copy succeeds into `.trash`, then the source refuses to go: the row is
      // kept, so the copy must go instead of piling up one per retry.
      final Directory locked = Directory(p.join(dir.path, 'locked'))
        ..createSync();
      final File source = File(p.join(locked.path, 'abc.m4a'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final RecordingsRepository copying = RecordingsRepository(
        directoryProvider: () async => dir,
        renameFile: (File source, String target) =>
            throw const FileSystemException('EXDEV', 'cross-device'),
      );
      final DateTime at = DateTime.utc(2026, 8, 28);
      final Recording item = Recording(
        id: 'abc',
        filePath: source.path,
        createdAt: at,
        durationMs: 1000,
        sizeBytes: 3,
        status: RecordingStatus.completed,
        type: CaptureType.audioRecording,
        segments: <CaptureSegment>[
          CaptureSegment(
            index: 0,
            filePath: source.path,
            type: CaptureType.audioRecording,
            createdAt: at,
            sizeBytes: 3,
          ),
        ],
      );
      await Process.run('chmod', <String>['0555', locked.path]);
      try {
        await expectLater(
          copying.trashArtifacts(item, held: false, now: now),
          throwsA(isA<FileSystemException>()),
        );
        expect(source.existsSync(), isTrue);
        expect(trash().listSync().whereType<File>(), isEmpty);
      } finally {
        await Process.run('chmod', <String>['0755', locked.path]);
      }
    }, skip: Platform.isWindows ? 'needs chmod' : false);

    test('trashes an artifact that lives outside the recordings dir', () async {
      final Directory other = await Directory.systemTemp.createTemp(
        'recordings-trash-other',
      );
      addTearDown(() => other.delete(recursive: true));
      final File outside = write('abc.m4a', into: other);
      final Recording elsewhere = Recording(
        id: 'abc',
        filePath: outside.path,
        createdAt: DateTime.utc(2026, 8, 28),
        durationMs: 1000,
        sizeBytes: 10,
        status: RecordingStatus.completed,
        type: CaptureType.audioRecording,
      );

      final int moved = await repository.trashArtifacts(
        elsewhere,
        held: false,
        now: now,
      );

      expect(moved, 1);
      expect(outside.existsSync(), isFalse);
      expect(trashed(), <String>['$nowMs-abc.m4a']);
    });

    test('findOrphans does not re-adopt a file sitting in .trash', () async {
      const String name = '3f2b8c1e-0a4d-4e7f-9b61-2c5d8e7a1f90.m4a';
      write(name, into: trash());
      write('held-$nowMs-$name', into: trash());

      final List<Recording> orphans = await repository.findOrphans(
        const <Recording>[],
      );

      expect(orphans, isEmpty);
    });
  });

  group('pruneTrash', () {
    test(
      'removes only entries older than the retention, never held ones',
      () async {
        final int old = now
            .subtract(
              RecordingsRepository.trashRetention + const Duration(days: 1),
            )
            .millisecondsSinceEpoch;
        final int fresh = now
            .subtract(
              RecordingsRepository.trashRetention - const Duration(days: 1),
            )
            .millisecondsSinceEpoch;
        write('$old-a.m4a', into: trash());
        write('$fresh-b.m4a', into: trash());
        write('held-$old-c.m4a', into: trash());
        write('not-a-timestamp.m4a', into: trash());

        final int removed = await repository.pruneTrash(now: now);

        expect(removed, 1);
        expect(
          trashed(),
          <String>['$fresh-b.m4a', 'held-$old-c.m4a', 'not-a-timestamp.m4a']
            ..sort(),
        );
      },
    );

    test('leaves a UUID-named file that is not a 13-digit stamp', () async {
      write('12345678-0a4d-4e7f-9b61-2c5d8e7a1f90.m4a', into: trash());
      write('3f2b8c1e-0a4d-4e7f-9b61-2c5d8e7a1f90.m4a', into: trash());

      expect(await repository.pruneTrash(now: now), 0);
      expect(trashed(), hasLength(2));
    });

    test('is a no-op when there is no trash yet', () async {
      expect(await repository.pruneTrash(now: now), 0);
    });
  });

  group('releaseHeldTrash', () {
    test(
      'renames held entries to the release time and starts the clock',
      () async {
        final int old = now
            .subtract(
              RecordingsRepository.trashRetention + const Duration(days: 5),
            )
            .millisecondsSinceEpoch;
        write('held-$old-c.m4a', into: trash());

        expect(await repository.releaseHeldTrash(now: now), 1);
        expect(trashed(), <String>['$nowMs-c.m4a']);
        expect(await repository.heldTrashCount(), 0);

        // Just released: a prune at the same moment keeps it ...
        expect(await repository.pruneTrash(now: now), 0);
        // ... and one past the retention removes it.
        final DateTime later = now.add(
          RecordingsRepository.trashRetention + const Duration(days: 1),
        );
        expect(await repository.pruneTrash(now: later), 1);
        expect(trashed(), isEmpty);
      },
    );
  });
}

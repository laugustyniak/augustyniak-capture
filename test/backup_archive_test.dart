import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/backup/data/zip_capture_archive.dart';
import 'package:augustyniak_capture/features/backup/domain/capture_archive.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';

/// The archive is the only answer this app has to a mobile reinstall, which
/// deletes the container the recordings live in. What is asserted here is
/// mostly what it *refuses* to do: overwrite a row, overwrite a file, or carry
/// a bearer token off the device.
void main() {
  late Directory source;
  late Directory target;
  late Directory scratch;

  RecordingsRepository repositoryFor(Directory directory) =>
      RecordingsRepository(directoryProvider: () async => directory);

  ProjectsRepository projectsFor(Directory directory) =>
      ProjectsRepository(directoryProvider: () async => directory);

  ZipCaptureArchive archiveFor(Directory directory) => ZipCaptureArchive(
    directoryProvider: () async => directory,
    recordings: repositoryFor(directory),
    projects: projectsFor(directory),
  );

  Recording capture(String id, {String extension = 'm4a'}) => Recording(
    id: id,
    filePath: p.join(source.path, '$id.$extension'),
    createdAt: DateTime(2026, 8, 5, 12),
    durationMs: 1000,
    sizeBytes: 12,
    status: RecordingStatus.completed,
    transcript: 'body of $id',
    title: 'Title $id',
  );

  /// Writes an index plus the source files it points at, the way the capture
  /// pipeline would have left them.
  Future<void> seed(Directory directory, List<Recording> recordings) async {
    for (final Recording item in recordings) {
      await File(
        p.join(directory.path, p.basename(item.filePath)),
      ).writeAsString('audio-${item.id}');
    }
    await repositoryFor(directory).saveAll(recordings);
  }

  setUp(() {
    source = Directory.systemTemp.createTempSync('capture_archive_src_');
    target = Directory.systemTemp.createTempSync('capture_archive_dst_');
    scratch = Directory.systemTemp.createTempSync('capture_archive_zip_');
  });
  tearDown(() {
    for (final Directory directory in <Directory>[source, target, scratch]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  File zipPath() => File(p.join(scratch.path, 'capture.zip'));

  test('a round trip restores the rows, the files and the text', () async {
    await seed(source, <Recording>[capture('a'), capture('b')]);

    final BackupSummary exported = await archiveFor(source).exportTo(zipPath());
    expect(exported.captures, 2);
    expect(exported.bytes, greaterThan(0));

    final RestoreSummary restored = await archiveFor(
      target,
    ).importFrom(zipPath());
    expect(restored.added, 2);
    expect(restored.alreadyPresent, 0);
    expect(restored.unreadable, 0);
    expect(restored.filesRestored, 2);

    final List<Recording> rows = await repositoryFor(target).loadAll();
    expect(rows.map((Recording item) => item.id).toSet(), <String>{'a', 'b'});
    // The transcript is the part no orphan sweep could ever bring back — it
    // only ever lived in the index.
    expect(rows.first.transcript, isNotNull);
    expect(rows.first.title, startsWith('Title '));
  });

  test('restored paths point into the importing install, not the exporting one', () async {
    await seed(source, <Recording>[capture('a')]);
    await archiveFor(source).exportTo(zipPath());
    await archiveFor(target).importFrom(zipPath());

    final Recording restored = (await repositoryFor(target).loadAll()).single;
    expect(p.dirname(restored.filePath), target.path);
    expect(File(restored.filePath).existsSync(), isTrue);
    expect(
      File(restored.filePath).readAsStringSync(),
      'audio-a',
      reason: 'the row must point at the bytes that came with it',
    );
  });

  test('an id already present is left exactly as it is', () async {
    await seed(source, <Recording>[capture('a')]);
    await archiveFor(source).exportTo(zipPath());

    // The local copy has moved on since the archive was taken — enriched,
    // retitled, ticked off. A restore must not be able to undo that.
    await seed(target, <Recording>[]);
    final Recording local = capture('a')
        .copyWith(title: 'Edited since the backup', isProcessedByUser: true);
    await File(p.join(target.path, 'a.m4a')).writeAsString('local audio');
    await repositoryFor(target).saveAll(<Recording>[local]);

    final RestoreSummary restored = await archiveFor(
      target,
    ).importFrom(zipPath());
    expect(restored.added, 0);
    expect(restored.alreadyPresent, 1);
    expect(restored.filesRestored, 0, reason: 'the file was already there');

    final Recording after = (await repositoryFor(target).loadAll()).single;
    expect(after.title, 'Edited since the backup');
    expect(after.isProcessedByUser, isTrue);
    expect(File(p.join(target.path, 'a.m4a')).readAsStringSync(), 'local audio');
  });

  test('an import adds to an existing queue rather than replacing it', () async {
    await seed(source, <Recording>[capture('fromBackup')]);
    await archiveFor(source).exportTo(zipPath());

    await seed(target, <Recording>[capture('alreadyHere')]);
    final RestoreSummary restored = await archiveFor(
      target,
    ).importFrom(zipPath());

    expect(restored.added, 1);
    final List<Recording> rows = await repositoryFor(target).loadAll();
    expect(
      rows.map((Recording item) => item.id).toSet(),
      <String>{'alreadyHere', 'fromBackup'},
      reason: 'the local queue must survive a restore intact',
    );
  });

  test('credentials and debug state never enter the archive', () async {
    await seed(source, <Recording>[capture('a')]);
    await File(p.join(source.path, 'settings.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'profiles': <dynamic>[
          <String, dynamic>{'bearerToken': 'enc:v1:super-secret'},
        ],
      }),
    );
    await File(p.join(source.path, 'logs.json')).writeAsString('[]');
    await File(
      p.join(source.path, 'gamification.json'),
    ).writeAsString('{"streak":4}');
    // A diagnostic copy of a failure, which must not be re-imported anywhere.
    await File(
      p.join(source.path, 'recordings.corrupt-2026-08-05.json'),
    ).writeAsString('garbage');

    await archiveFor(source).exportTo(zipPath());
    final String raw = String.fromCharCodes(zipPath().readAsBytesSync());
    expect(raw.contains('super-secret'), isFalse);
    expect(raw.contains('settings.json'), isFalse);
    expect(raw.contains('logs.json'), isFalse);
    expect(raw.contains('gamification.json'), isFalse);
    expect(raw.contains('recordings.corrupt-'), isFalse);

    await archiveFor(target).importFrom(zipPath());
    expect(File(p.join(target.path, 'settings.json')).existsSync(), isFalse);
  });

  test('append-only journals merge without duplicating a line', () async {
    await seed(source, <Recording>[capture('a')]);
    const String shared = '{"recordingId":"a","field":"title"}';
    const String only = '{"recordingId":"a","field":"summary"}';
    await File(
      p.join(source.path, 'revisions.jsonl'),
    ).writeAsString('$shared\n$only\n');
    await archiveFor(source).exportTo(zipPath());

    await File(
      p.join(target.path, 'revisions.jsonl'),
    ).writeAsString('$shared\n');
    await archiveFor(target).importFrom(zipPath());

    final List<String> lines = const LineSplitter()
        .convert(File(p.join(target.path, 'revisions.jsonl')).readAsStringSync())
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    expect(lines.length, 2);
    expect(lines.where((String line) => line == shared).length, 1);
    expect(lines, contains(only));
  });

  test('projects come across, and the active selection stays local', () async {
    await seed(source, <Recording>[capture('a')]);
    await projectsFor(source).saveAll(
      <Project>[
        const Project(id: 'p1', name: 'Backed up', repoPath: '/tmp/one'),
      ],
      activeProjectId: 'p1',
    );
    await archiveFor(source).exportTo(zipPath());

    await projectsFor(target).saveAll(
      <Project>[const Project(id: 'p2', name: 'Local', repoPath: '/tmp/two')],
      activeProjectId: 'p2',
    );
    await archiveFor(target).importFrom(zipPath());

    final ProjectsRepository projects = projectsFor(target);
    final List<Project> after = await projects.loadAll();
    expect(after.map((Project item) => item.id).toSet(), <String>{'p1', 'p2'});
    expect(
      projects.loadedActiveProjectId,
      'p2',
      reason:
          'importing a backup must not repoint which project new captures '
          'inherit',
    );
  });

  test('a file that is not a capture archive is refused by name', () async {
    final File notAnArchive = File(p.join(scratch.path, 'holiday.zip'))
      ..writeAsStringSync('this is not a zip at all');
    expect(
      () => archiveFor(target).importFrom(notAnArchive),
      throwsA(isA<ArchiveUnreadableException>()),
    );
  });

  test('an empty install exports an archive that imports cleanly', () async {
    final BackupSummary exported = await archiveFor(source).exportTo(zipPath());
    expect(exported.captures, 0);

    final RestoreSummary restored = await archiveFor(
      target,
    ).importFrom(zipPath());
    expect(restored.added, 0);
    expect(restored.unreadable, 0);
  });

  test('a malformed row is dropped without costing the rest of the archive', () async {
    await seed(source, <Recording>[capture('a'), capture('b')]);
    // Hand-edit the archived index the way a truncated sync would.
    final File index = File(p.join(source.path, 'recordings.json'));
    final List<dynamic> rows =
        jsonDecode(index.readAsStringSync()) as List<dynamic>;
    rows.add(<String, dynamic>{'id': null});
    index.writeAsStringSync(jsonEncode(rows));

    await archiveFor(source).exportTo(zipPath());
    final RestoreSummary restored = await archiveFor(
      target,
    ).importFrom(zipPath());

    expect(restored.added, 2);
    expect(restored.unreadable, 1);
  });
}

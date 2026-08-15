import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/backup/domain/capture_archive.dart';
import 'package:augustyniak_capture/features/backup/presentation/backup_coordinator.dart';

/// Records what it was asked to archive and writes a plausible file, so the
/// coordinator's staging and clean-up can be observed without a real zip.
class _RecordingArchive implements CaptureArchive {
  _RecordingArchive({this.failWith});

  final Object? failWith;
  File? staged;

  @override
  Future<BackupSummary> exportTo(File destination) async {
    if (failWith != null) throw failWith!;
    await destination.writeAsString('archive bytes');
    staged = destination;
    return BackupSummary(
      captures: 3,
      files: 4,
      bytes: await destination.length(),
      destination: destination.path,
    );
  }

  @override
  Future<RestoreSummary> importFrom(File source) async {
    if (failWith != null) throw failWith!;
    return const RestoreSummary(
      added: 2,
      alreadyPresent: 1,
      unreadable: 0,
      filesRestored: 2,
    );
  }
}

class _FakePicker implements ArchiveLocationPicker {
  _FakePicker({this.destination, this.archive});

  final String? destination;
  final File? archive;
  File? delivered;

  @override
  Future<String?> deliver(File staged, String suggestedName) async {
    // Read here rather than after the call: the coordinator deletes its staging
    // directory on the way out, so a picker that only kept the handle would be
    // asserting against a file that no longer exists.
    delivered = staged;
    if (destination == null) return null;
    expect(staged.existsSync(), isTrue, reason: 'delivered before clean-up');
    return destination;
  }

  @override
  Future<File?> chooseArchive() async => archive;
}

void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('backup_coord_'));
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  BackupCoordinator coordinator({
    CaptureArchive? archive,
    ArchiveLocationPicker? picker,
  }) => BackupCoordinator(
    archive: archive ?? _RecordingArchive(),
    picker: picker ?? _FakePicker(destination: '/somewhere/backup.zip'),
    now: () => DateTime(2026, 8, 6),
  );

  test('the suggested name is dated and sorts', () {
    expect(
      coordinator().suggestedName(),
      'augustyniak-capture-2026-08-06.zip',
    );
  });

  test('an export reports where the picker actually put it', () async {
    final BackupSummary? summary = await coordinator().export();
    expect(summary, isNotNull);
    expect(summary!.captures, 3);
    expect(
      summary.destination,
      '/somewhere/backup.zip',
      reason:
          'the archive names its staging path; only the picker knows where the '
          'file ended up',
    );
  });

  test('a cancelled save is not an error and leaves nothing staged', () async {
    final _FakePicker picker = _FakePicker(); // destination null = cancelled
    expect(await coordinator(picker: picker).export(), isNull);
    expect(picker.delivered, isNotNull);
    expect(
      picker.delivered!.existsSync(),
      isFalse,
      reason: 'the staging directory must be gone once export returns',
    );
  });

  test('a failed export cleans up and rethrows rather than reporting success', () async {
    final BackupCoordinator subject = coordinator(
      archive: _RecordingArchive(failWith: const FileSystemException('disk')),
    );
    await expectLater(subject.export(), throwsA(isA<FileSystemException>()));
    expect(
      scratch.listSync(),
      isEmpty,
      reason: 'nothing of a failed export belongs in the working directory',
    );
  });

  test('a cancelled import never touches the archive', () async {
    final _RecordingArchive archive = _RecordingArchive();
    final BackupCoordinator subject = coordinator(
      archive: archive,
      picker: _FakePicker(), // chooseArchive returns null
    );
    expect(await subject.import(), isNull);
  });

  test('an import passes the chosen file through and returns its counts', () async {
    final File chosen = File('${scratch.path}/incoming.zip')
      ..writeAsStringSync('x');
    final RestoreSummary? summary = await coordinator(
      picker: _FakePicker(archive: chosen),
    ).import();

    expect(summary, isNotNull);
    expect(summary!.added, 2);
    expect(summary.alreadyPresent, 1);
    expect(summary.filesRestored, 2);
  });
}

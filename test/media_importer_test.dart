import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voice_notes_phase1/features/recordings/data/media_importer.dart';
import 'package:voice_notes_phase1/features/recordings/data/media_picker.dart';
import 'package:voice_notes_phase1/features/recordings/data/recordings_repository.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_type.dart';
import 'package:voice_notes_phase1/features/recordings/domain/recording.dart';

/// Points `createSourceFile` at a temp dir so the importer runs without
/// path_provider — the same "extend and override only IO" trick as the
/// settings-repository fake.
class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));
}

void main() {
  late Directory appDir;
  late Directory pickDir;
  late MediaImporter importer;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('audivoa_app_');
    pickDir = Directory.systemTemp.createTempSync('audivoa_pick_');
    importer = MediaImporter(_FakeRepository(appDir));
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
  });

  File writePicked(String name, String content) {
    final File file = File(p.join(pickDir.path, name))
      ..writeAsStringSync(content);
    return file;
  }

  test('copies the source into the app dir and returns a saved item', () async {
    final File source = writePicked('holiday.png', 'PNGDATA');
    final DateTime now = DateTime.utc(2026, 7, 25);

    final Recording item = await importer.importFile(
      id: 'abc',
      type: CaptureType.image,
      source: source,
      mimeType: 'image/png',
      createdAt: now,
    );

    expect(item.id, 'abc');
    expect(item.type, CaptureType.image);
    expect(item.sourceMimeType, 'image/png');
    expect(item.status, RecordingStatus.saved);
    expect(item.durationMs, 0);
    expect(item.createdAt, now);
    // Stored under <id>.<ext-from-mime> in the app dir, not the pick dir.
    expect(p.basename(item.filePath), 'abc.png');
    expect(File(item.filePath).parent.path, appDir.path);
    expect(File(item.filePath).readAsStringSync(), 'PNGDATA');
  });

  test('derives the extension from the capture type when mime is absent',
      () async {
    final File source = writePicked('clip.bin', 'AUDIO');

    final Recording item = await importer.importFile(
      id: 'up1',
      type: CaptureType.audioUpload,
      source: source,
      createdAt: DateTime.utc(2026),
    );

    // audioUpload with no mime falls back to m4a.
    expect(p.basename(item.filePath), 'up1.m4a');
  });

  test('leaves the picked source file in place (never moves or deletes it)',
      () async {
    final File source = writePicked('note.mp3', 'SOUND');

    await importer.importFile(
      id: 'k',
      type: CaptureType.audioUpload,
      source: source,
      mimeType: 'audio/mpeg',
      createdAt: DateTime.utc(2026),
    );

    expect(source.existsSync(), isTrue, reason: 'source must survive import');
  });

  test('throws on a missing source and indexes nothing', () async {
    final File missing = File(p.join(pickDir.path, 'gone.png'));

    await expectLater(
      importer.importFile(
        id: 'x',
        type: CaptureType.image,
        source: missing,
        createdAt: DateTime.utc(2026),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(appDir.listSync(), isEmpty);
  });

  test('throws on an empty source', () async {
    final File empty = writePicked('empty.png', '');

    await expectLater(
      importer.importFile(
        id: 'y',
        type: CaptureType.image,
        source: empty,
        createdAt: DateTime.utc(2026),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  group('FilePickerMediaPicker.mimeForPath', () {
    test('maps known extensions and returns null for the rest', () {
      expect(FilePickerMediaPicker.mimeForPath('/a/b.png'), 'image/png');
      expect(FilePickerMediaPicker.mimeForPath('/a/b.JPG'), 'image/jpeg');
      expect(FilePickerMediaPicker.mimeForPath('/a/b.mp3'), 'audio/mpeg');
      expect(FilePickerMediaPicker.mimeForPath('/a/b.mov'), 'video/quicktime');
      expect(FilePickerMediaPicker.mimeForPath('/a/b.xyz'), isNull);
    });
  });
}

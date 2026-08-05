import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/recordings/data/markdown_note_vault.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/note_vault.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _FakePicker implements MediaPicker {
  _FakePicker(this._result);
  final PickedMedia? _result;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => _result;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakeRecorder implements AudioRecorder {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _StubTranscription implements TranscriptionService {
  _StubTranscription(this.result);
  final String result;
  @override
  Future<String> transcribe(File audioFile) async => result;
}

/// A vault whose every write fails — an unmounted drive, a read-only folder.
class _FailingVault implements NoteVault {
  int attempts = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<VaultWrite> mirror(VaultNote note) async {
    attempts++;
    throw const FileSystemException('vault unavailable');
  }
}

/// Counts writes without touching a disk, for the questions that are about
/// *how often* the mirror runs rather than what it produces.
class _CountingVault implements NoteVault {
  final List<VaultNote> notes = <VaultNote>[];

  @override
  bool get isConfigured => true;

  @override
  Future<VaultWrite> mirror(VaultNote note) async {
    notes.add(note);
    return const VaultWrite(outcome: VaultOutcome.created);
  }
}

void main() {
  late Directory appDir;
  late Directory pickDir;
  late Directory vaultDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('vault_app_');
    pickDir = Directory.systemTemp.createTempSync('vault_pick_');
    vaultDir = Directory.systemTemp.createTempSync('vault_root_');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
    vaultDir.deleteSync(recursive: true);
  });

  PickedMedia audioSource() {
    final File file = File(p.join(pickDir.path, 'memo.m4a'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    return PickedMedia(file: file, mimeType: 'audio/mp4');
  }

  RecordingsController build({
    required NoteVault vault,
    TranscriptionService? transcription,
    PickedMedia? picked,
  }) {
    return RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService:
          transcription ?? const DisabledTranscriptionService(),
      mediaPicker: _FakePicker(picked),
      noteVault: vault,
      recorder: _FakeRecorder(),
      player: _FakePlayer(),
    );
  }

  MarkdownNoteVault realVault() =>
      MarkdownNoteVault(vaultPath: () => vaultDir.path);

  List<File> notes() {
    final Directory dir = Directory(
      p.join(vaultDir.path, VaultDefaults.folder),
    );
    if (!dir.existsSync()) return <File>[];
    return dir
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.md'))
        .toList();
  }

  test('a completed capture lands in the vault', () async {
    final RecordingsController controller = build(
      vault: realVault(),
      transcription: _StubTranscription('Treść nagrania.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(notes(), hasLength(1));
    expect(notes().single.readAsStringSync(), contains('Treść nagrania.'));
  });

  test('a failed capture writes no note', () async {
    // No transcription profile configured — the processor throws.
    final RecordingsController controller = build(
      vault: realVault(),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(notes(), isEmpty);
  });

  test('a hand edit updates the note that already exists', () async {
    final RecordingsController controller = build(
      vault: realVault(),
      transcription: _StubTranscription('Pierwsza wersja.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    final String path = notes().single.path;

    await controller.setTitle(controller.recordings.single.id, 'Mój tytuł');

    expect(notes(), hasLength(1));
    expect(notes().single.path, path);
    expect(notes().single.readAsStringSync(), contains('# Mój tytuł'));
  });

  test('a note edited in the vault survives a later hand edit', () async {
    final RecordingsController controller = build(
      vault: realVault(),
      transcription: _StubTranscription('Wersja z modelu.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    final File note = notes().single;
    note.writeAsStringSync('${note.readAsStringSync()}\nDopisane ręcznie.\n');
    final String edited = note.readAsStringSync();

    await controller.setTitle(controller.recordings.single.id, 'Nowy tytuł');

    expect(note.readAsStringSync(), edited);
    // The capture itself still took the edit — only the copy stepped back.
    expect(controller.recordings.single.title, 'Nowy tytuł');
  });

  test('a status transition alone does not rewrite the note', () async {
    final _CountingVault vault = _CountingVault();
    final RecordingsController controller = build(
      vault: vault,
      transcription: _StubTranscription('Tekst.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    // One write for the whole capture: `saved`, `pendingTranscription` and
    // `transcribing` all pass through `_update` and none of them reach here.
    expect(vault.notes, hasLength(1));

    await controller.toggleProcessed(controller.recordings.single.id);
    expect(vault.notes, hasLength(1));
  });

  test('a vault that refuses never fails the capture', () async {
    final _FailingVault vault = _FailingVault();
    final RecordingsController controller = build(
      vault: vault,
      transcription: _StubTranscription('Tekst mimo wszystko.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(vault.attempts, 1);
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, 'Tekst mimo wszystko.');
    expect(item.error, isNull);
    expect(controller.error, isNull);
  });

  test('with no vault configured nothing is written and nothing breaks', () async {
    final RecordingsController controller = build(
      vault: const DisabledNoteVault(),
      transcription: _StubTranscription('Tekst.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    expect(controller.mirrorsToVault, isFalse);
    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(await controller.mirrorAll(), isA<VaultMirrorSummary>());
    expect(controller.error, isNull);
  });

  test('mirrorAll backfills captures taken before the vault existed', () async {
    // Captured with the mirror off, which is every capture on an install that
    // configures a vault later.
    final RecordingsController before = build(
      vault: const DisabledNoteVault(),
      transcription: _StubTranscription('Stara notatka.'),
      picked: audioSource(),
    );
    await before.addTextNote('notatka pisana ręcznie');
    await before.waitForProcessing();
    expect(notes(), isEmpty);

    final RecordingsController after = build(vault: realVault());
    await after.addTextNote('notatka pisana ręcznie');
    await after.waitForProcessing();
    // Re-running the sweep must not add a second copy of the same note.
    final VaultMirrorSummary summary = await after.mirrorAll();

    expect(notes(), hasLength(1));
    expect(summary.unchanged, 1);
    expect(summary.created, 0);
  });
}

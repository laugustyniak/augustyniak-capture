import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/recordings/data/markdown_note_vault.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/revisions_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/note_vault.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._items);
  List<Recording> _items;
  int saveCount = 0;
  @override
  Future<List<Recording>> loadAll() async => List<Recording>.from(_items);
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCount++;
    _items = List<Recording>.of(recordings);
  }
}

class _FakeRevisions extends RevisionsRepository {
  final List<RecordingRevision> appended = <RecordingRevision>[];
  @override
  Future<Map<String, List<RecordingRevision>>> load() async =>
      <String, List<RecordingRevision>>{};
  @override
  Future<void> append(List<RecordingRevision> revisions) async =>
      appended.addAll(revisions);
}

Recording _seed({
  String id = 'r1',
  String? title,
  String transcript = 'oryginalny tekst',
}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.utc(2026, 7, 25, 10, 30),
  durationMs: 1000,
  status: RecordingStatus.completed,
  title: title,
  transcript: transcript,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  group('editTranscript', () {
    test('overwrites the text (trimmed), notifies listeners, and persists', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      int notifications = 0;
      c.addListener(() => notifications++);

      await c.editTranscript('r1', '  poprawiony tekst  ');

      expect(c.recordings.single.transcript, 'poprawiony tekst');
      expect(repo.saveCount, greaterThan(0));
      expect(notifications, greaterThan(0));
    });

    test('a blank edit is ignored and does not notify or persist', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      int notifications = 0;
      c.addListener(() => notifications++);

      await c.editTranscript('r1', '   ');

      expect(c.recordings.single.transcript, 'oryginalny tekst');
      expect(repo.saveCount, 0);
      expect(notifications, 0);
    });

    test('records revision history when transcript is edited', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final _FakeRevisions revisionsRepo = _FakeRevisions();
      final RecordingsController c = RecordingsController(
        repository: repo,
        revisionsRepository: revisionsRepo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.editTranscript('r1', 'nowy tekst 1');
      await c.editTranscript('r1', 'nowy tekst 2');

      final List<RecordingRevision> revisions = c.revisionsFor('r1');
      expect(revisions, hasLength(2));
      expect(revisions.first.field, 'transcript');
      expect(revisions.first.from, 'nowy tekst 1');
      expect(revisions.first.to, 'nowy tekst 2');
      expect(revisions.first.source, RevisionSource.user);
      expect(revisions.last.from, 'oryginalny tekst');
      expect(revisions.last.to, 'nowy tekst 1');
      expect(revisionsRepo.appended, hasLength(2));
    });
  });

  group('setTitle', () {
    test('sets a trimmed title, notifies listeners, and persists', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed()]);
      final RecordingsController c = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      int notifications = 0;
      c.addListener(() => notifications++);

      await c.setTitle('r1', '  Spotkanie z zespołem  ');

      expect(c.recordings.single.title, 'Spotkanie z zespołem');
      expect(repo.saveCount, greaterThan(0));
      expect(notifications, greaterThan(0));
    });

    test('an empty title clears it back to null', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed(title: 'Stary tytuł')]);
      final RecordingsController c = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', '   ');

      expect(c.recordings.single.title, isNull);
      expect(repo.saveCount, greaterThan(0));
    });

    test('records revision history when title is changed or cleared', () async {
      final _FakeRepo repo = _FakeRepo(<Recording>[_seed(title: 'Oryginalny')]);
      final _FakeRevisions revisionsRepo = _FakeRevisions();
      final RecordingsController c = RecordingsController(
        repository: repo,
        revisionsRepository: revisionsRepo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', 'Zmieniony');
      await c.setTitle('r1', '');

      final List<RecordingRevision> revisions = c.revisionsFor('r1');
      expect(revisions, hasLength(2));
      expect(revisions.first.field, 'title');
      expect(revisions.first.from, 'Zmieniony');
      expect(revisions.first.to, isNull);
      expect(revisions.last.from, 'Oryginalny');
      expect(revisions.last.to, 'Zmieniony');
      expect(revisionsRepo.appended, hasLength(2));
    });
  });

  group('persistence across reload with real repository', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('capture_edit_test_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('edited title and transcript persist across repository reload', () async {
      final RecordingsRepository repo = RecordingsRepository(
        directoryProvider: () async => tempDir,
      );

      final RecordingsController controller1 = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      await controller1.initialize();

      // Seed initial recording by saving through controller / repo
      await repo.saveAll(<Recording>[
        _seed(id: 'persist-1', title: 'Startowy tytuł', transcript: 'Startowy tekst'),
      ]);
      await controller1.reloadFromStorage();

      await controller1.setTitle('persist-1', 'Zaktualizowany tytuł');
      await controller1.editTranscript('persist-1', 'Zaktualizowany transkrypt');
      controller1.dispose();

      // Create fresh controller and initialize from disk
      final RecordingsController controller2 = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller2.dispose);
      await controller2.initialize();

      final Recording loaded = controller2.recordings.singleWhere(
        (Recording r) => r.id == 'persist-1',
      );
      expect(loaded.title, 'Zaktualizowany tytuł');
      expect(loaded.transcript, 'Zaktualizowany transkrypt');
    });
  });

  group('vault mirror integration on title and transcript edits', () {
    late Directory tempVaultDir;
    late Directory tempAppDir;

    setUp(() {
      tempVaultDir = Directory.systemTemp.createTempSync('vault_edit_');
      tempAppDir = Directory.systemTemp.createTempSync('app_edit_');
    });

    tearDown(() {
      tempVaultDir.deleteSync(recursive: true);
      tempAppDir.deleteSync(recursive: true);
    });

    List<File> vaultNoteFiles() {
      final Directory notesDir = Directory(
        p.join(tempVaultDir.path, VaultDefaults.folder),
      );
      if (!notesDir.existsSync()) return <File>[];
      return notesDir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.md'))
          .toList();
    }

    test('editing title and transcript syncs directly to vault mirror note', () async {
      final MarkdownNoteVault noteVault = MarkdownNoteVault(
        vaultPath: () => tempVaultDir.path,
      );
      final _FakeRepo repo = _FakeRepo(<Recording>[
        _seed(id: 'vault-edit-1', transcript: 'Pierwotna treść transkryptu.'),
      ]);

      final RecordingsController controller = RecordingsController(
        repository: repo,
        noteVault: noteVault,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      // Mirror initial note to vault
      await controller.mirrorAll();
      expect(vaultNoteFiles(), hasLength(1));
      final File noteFile = vaultNoteFiles().single;
      expect(noteFile.readAsStringSync(), contains('Pierwotna treść transkryptu.'));

      // Edit title
      await controller.setTitle('vault-edit-1', 'Nowy Tytuł Notatki');
      expect(vaultNoteFiles(), hasLength(1));
      String content = noteFile.readAsStringSync();
      expect(content, contains('title: "Nowy Tytuł Notatki"'));
      expect(content, contains('# Nowy Tytuł Notatki'));

      // Edit transcript
      await controller.editTranscript(
        'vault-edit-1',
        'Zaktualizowany pełny tekst transkrypcji.',
      );
      expect(vaultNoteFiles(), hasLength(1));
      content = noteFile.readAsStringSync();
      expect(content, contains('Zaktualizowany pełny tekst transkrypcji.'));
      expect(content, contains('title: "Nowy Tytuł Notatki"'));
    });
  });
}

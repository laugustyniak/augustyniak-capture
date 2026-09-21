import 'dart:io';

import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/data/repository_sync_applier.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording(String id) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.utc(2026, 1, 1),
  durationMs: 1000,
  status: RecordingStatus.completed,
);

void main() {
  late Directory dir;
  late ClipboardRepository clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-repository-sync-applier-',
    );
    clipboard = LocalJsonClipboardRepository(
      storageDirectoryProvider: () async => dir,
    );
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  RepositorySyncApplier buildApplier({
    Future<void> Function(List<Recording>)? applySyncedRecordings,
    Future<void> Function(List<Project>)? applySyncedProjects,
    Future<void> Function(String)? applySyncedProjectDelete,
    Future<void> Function(String)? deleteRecording,
    bool Function(String)? recordingExists,
  }) {
    return RepositorySyncApplier(
      applySyncedRecordings: applySyncedRecordings ?? (List<Recording> _) async {},
      applySyncedProjects: applySyncedProjects ?? (List<Project> _) async {},
      applySyncedProjectDelete: applySyncedProjectDelete ?? (String _) async {},
      clipboard: clipboard,
      revisions: null,
      deleteRecording: deleteRecording ?? (String _) async {},
      recordingExists: recordingExists ?? (String _) => false,
    );
  }

  test('upsertRecordings delegates the whole batch to the controller callback', () async {
    List<Recording>? received;
    final RepositorySyncApplier applier = buildApplier(
      applySyncedRecordings: (List<Recording> rows) async {
        received = rows;
      },
    );

    final List<Recording> rows = <Recording>[_recording('a'), _recording('b')];
    await applier.upsertRecordings(rows);

    expect(received, same(rows));
  });

  test('upsertProjects delegates the whole batch to the controller callback', () async {
    List<Project>? received;
    final RepositorySyncApplier applier = buildApplier(
      applySyncedProjects: (List<Project> rows) async {
        received = rows;
      },
    );

    final List<Project> rows = <Project>[
      const Project(id: 'p1', name: 'One', repoPath: '/one'),
    ];
    await applier.upsertProjects(rows);

    expect(received, same(rows));
  });

  group('deleteRecording — the refusal check', () {
    test('completes normally when the delete actually happened', () async {
      final List<String> calledWith = <String>[];
      final RepositorySyncApplier applier = buildApplier(
        deleteRecording: (String id) async => calledWith.add(id),
        recordingExists: (String id) => false, // gone, as expected
      );

      await applier.deleteRecording('a');

      expect(calledWith, <String>['a']);
    });

    test('throws when the row is still present after a refused delete', () async {
      final RepositorySyncApplier applier = buildApplier(
        // Simulates `RecordingsController.deleteRecording` returning
        // normally on a refusal (index unreadable, a file that would not
        // delete) rather than throwing.
        deleteRecording: (String id) async {},
        recordingExists: (String id) => true, // still there — refused
      );

      await expectLater(
        applier.deleteRecording('a'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('deleteProject delegates the id to the controller callback', () async {
    final List<String> calledWith = <String>[];
    final RepositorySyncApplier applier = buildApplier(
      applySyncedProjectDelete: (String id) async => calledWith.add(id),
    );

    await applier.deleteProject('p1');

    expect(calledWith, <String>['p1']);
  });

  group('upsertClipboardItems / deleteClipboardItem', () {
    test('adds a new id and updates text only when it differs', () async {
      await clipboard.addItem(
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'same', copiedAt: DateTime.utc(2026, 1, 1)),
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.upsertClipboardItems(<ClipboardItem>[
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'same', copiedAt: DateTime.utc(2026, 1, 1)),
        ClipboardItem(id: 'c2', type: ClipboardItemType.text, text: 'new one', copiedAt: DateTime.utc(2026, 1, 2)),
      ]);

      final List<ClipboardItem> items = await clipboard.getItems();
      expect(items.map((ClipboardItem c) => c.id), containsAll(<String>['c1', 'c2']));
      expect(items.firstWhere((ClipboardItem c) => c.id == 'c1').text, 'same');
    });

    test('an existing id with different text is updated in place', () async {
      await clipboard.addItem(
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'old', copiedAt: DateTime.utc(2026, 1, 1)),
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.upsertClipboardItems(<ClipboardItem>[
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'edited', copiedAt: DateTime.utc(2026, 1, 1)),
      ]);

      final List<ClipboardItem> items = await clipboard.getItems();
      expect(items.firstWhere((ClipboardItem c) => c.id == 'c1').text, 'edited');
    });

    test('deleting an unknown clipboard id is a no-op', () async {
      await clipboard.addItem(
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'keep', copiedAt: DateTime.utc(2026, 1, 1)),
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.deleteClipboardItem('does-not-exist');

      final List<ClipboardItem> items = await clipboard.getItems();
      expect(items.map((ClipboardItem c) => c.id), <String>['c1']);
    });

    test(
      'a pulled item whose text equals the newest local one is inserted, '
      'not dropped by the adjacent-content dedupe',
      () async {
        await clipboard.addItem(
          ClipboardItem(
            id: 'local-1',
            type: ClipboardItemType.text,
            text: 'same text',
            copiedAt: DateTime.utc(2026, 1, 1),
          ),
        );
        final RepositorySyncApplier applier = buildApplier();

        await applier.upsertClipboardItems(<ClipboardItem>[
          ClipboardItem(
            id: 'pulled-1',
            type: ClipboardItemType.text,
            text: 'same text',
            copiedAt: DateTime.utc(2026, 1, 2),
          ),
        ]);

        final List<ClipboardItem> items = await clipboard.getItems();
        expect(
          items.map((ClipboardItem c) => c.id),
          containsAll(<String>['local-1', 'pulled-1']),
        );
      },
    );

    test('deleting a known clipboard id removes it', () async {
      await clipboard.addItem(
        ClipboardItem(id: 'c1', type: ClipboardItemType.text, text: 'gone', copiedAt: DateTime.utc(2026, 1, 1)),
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.deleteClipboardItem('c1');

      expect(await clipboard.getItems(), isEmpty);
    });
  });

  test('appendRevisions is a no-op when the repository is null', () async {
    final RepositorySyncApplier applier = buildApplier();
    // Must not throw with no RevisionsRepository configured.
    await applier.appendRevisions(<RecordingRevision>[]);
  });
}

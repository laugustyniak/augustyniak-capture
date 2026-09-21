import 'dart:io';

import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/data/repository_sync_applier.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording(String id, {DateTime? createdAt, String? title}) =>
    Recording(
      id: id,
      filePath: '/tmp/$id.m4a',
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      durationMs: 1000,
      status: RecordingStatus.completed,
      title: title,
    );

void main() {
  late Directory dir;
  late RecordingsRepository recordings;
  late ProjectsRepository projects;
  late ClipboardRepository clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-repository-sync-applier-',
    );
    recordings = RecordingsRepository(directoryProvider: () async => dir);
    projects = ProjectsRepository(directoryProvider: () async => dir);
    clipboard = LocalJsonClipboardRepository(
      storageDirectoryProvider: () async => dir,
    );
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  RepositorySyncApplier buildApplier({
    List<String> deletedRecordingIds = const <String>[],
    Future<void> Function()? afterRecordingsWrite,
  }) {
    return RepositorySyncApplier(
      recordings: recordings,
      projects: projects,
      clipboard: clipboard,
      revisions: null,
      deleteRecording: (String id) async {
        deletedRecordingIds.add(id);
      },
      afterRecordingsWrite: afterRecordingsWrite,
    );
  }

  group('upsertRecordings', () {
    test('inserts new rows and replaces an existing id, keeping the rest', () async {
      await recordings.saveAll(<Recording>[
        _recording('a', title: 'original'),
        _recording('b'),
      ]);
      final RepositorySyncApplier applier = buildApplier();

      await applier.upsertRecordings(<Recording>[
        _recording('a', title: 'from server'),
        _recording('c'),
      ]);

      final List<Recording> stored = await recordings.loadAll();
      final Map<String, Recording> byId = <String, Recording>{
        for (final Recording r in stored) r.id: r,
      };
      expect(byId.keys, containsAll(<String>['a', 'b', 'c']));
      expect(byId['a']!.title, 'from server');
    });

    test('calls afterRecordingsWrite once the write lands', () async {
      int calls = 0;
      final RepositorySyncApplier applier = buildApplier(
        afterRecordingsWrite: () async {
          calls++;
        },
      );

      await applier.upsertRecordings(<Recording>[_recording('a')]);

      expect(calls, 1);
    });

    test('an empty batch writes nothing and does not call afterRecordingsWrite', () async {
      int calls = 0;
      final RepositorySyncApplier applier = buildApplier(
        afterRecordingsWrite: () async {
          calls++;
        },
      );

      await applier.upsertRecordings(<Recording>[]);

      expect(calls, 0);
      expect(await recordings.loadAll(), isEmpty);
    });
  });

  group('deleteRecording', () {
    test('delegates to the provided callback', () async {
      final List<String> deleted = <String>[];
      final RepositorySyncApplier applier = buildApplier(
        deletedRecordingIds: deleted,
      );

      await applier.deleteRecording('missing-id');

      expect(deleted, <String>['missing-id']);
    });
  });

  group('upsertProjects / deleteProject', () {
    test('inserts, merges and keeps the active project id unchanged', () async {
      await projects.saveAll(
        <Project>[const Project(id: 'p1', name: 'One', repoPath: '/one')],
        activeProjectId: 'p1',
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.upsertProjects(<Project>[
        const Project(id: 'p1', name: 'One renamed', repoPath: '/one'),
        const Project(id: 'p2', name: 'Two', repoPath: '/two'),
      ]);

      final List<Project> stored = await projects.loadAll();
      expect(stored.map((Project p) => p.id), containsAll(<String>['p1', 'p2']));
      expect(
        stored.firstWhere((Project p) => p.id == 'p1').name,
        'One renamed',
      );
      expect(projects.loadedActiveProjectId, 'p1');
    });

    test('deleting an unknown project id is a no-op', () async {
      await projects.saveAll(
        <Project>[const Project(id: 'p1', name: 'One', repoPath: '/one')],
        activeProjectId: 'p1',
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.deleteProject('does-not-exist');

      final List<Project> stored = await projects.loadAll();
      expect(stored, hasLength(1));
      expect(projects.loadedActiveProjectId, 'p1');
    });

    test('deleting the active project reassigns to a remaining one', () async {
      await projects.saveAll(
        <Project>[
          const Project(id: 'p1', name: 'One', repoPath: '/one'),
          const Project(id: 'p2', name: 'Two', repoPath: '/two'),
        ],
        activeProjectId: 'p1',
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.deleteProject('p1');

      final List<Project> stored = await projects.loadAll();
      expect(stored.map((Project p) => p.id), <String>['p2']);
      expect(projects.loadedActiveProjectId, 'p2');
    });

    test('deleting the only project leaves no active project', () async {
      await projects.saveAll(
        <Project>[const Project(id: 'p1', name: 'One', repoPath: '/one')],
        activeProjectId: 'p1',
      );
      final RepositorySyncApplier applier = buildApplier();

      await applier.deleteProject('p1');

      expect(await projects.loadAll(), isEmpty);
      expect(projects.loadedActiveProjectId, isNull);
    });
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

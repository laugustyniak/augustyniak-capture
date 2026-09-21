import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_transport.dart';
import 'sync_fixtures.dart';

void main() {
  late FakeSyncTransport transport;
  late MemoryBookkeeping bookkeeping;
  late RecordingApplier applier;
  late SyncEngine engine;
  final DateTime t0 = DateTime.utc(2026, 9, 21, 12);

  setUp(() {
    transport = FakeSyncTransport(clock: () => t0);
    bookkeeping = MemoryBookkeeping();
    applier = RecordingApplier();
    engine = SyncEngine(
      transport: transport,
      bookkeeping: bookkeeping,
      applier: applier,
      clock: () => t0,
    );
  });

  Future<void> seedServer(Recording r, {int version = 1}) => transport.push(
    SyncTable.recordings,
    [{...SyncRowCodec.recording(r), 'version': version}],
  );

  void advance(Duration d) => transport.clock = () => t0.add(d);

  test('a row the device has never seen is inserted and bookkept', () async {
    await seedServer(recording(id: 'a', title: 'srv'));
    advance(const Duration(minutes: 1));
    final r = await engine.run(const SyncSnapshot());
    expect(r.pulled, 1);
    expect(applier.recordings['a']!.title, 'srv');
    expect(bookkeeping.loadTable('recordings')['a']!.serverVersion, 1);
  });

  test('a clean local row is replaced by a newer server row', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'v1')]));
    await transport.push(SyncTable.recordings, [
      {...SyncRowCodec.recording(recording(id: 'a', title: 'v2')), 'version': 2},
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'v1')]));
    expect(applier.recordings['a']!.title, 'v2');
    expect(applier.revisions, isEmpty, reason: 'nothing local was overwritten');
  });

  test('server wins a conflict and every overwritten field becomes a sync revision', () async {
    await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'base', summary: 'base')]),
    );
    await transport.push(SyncTable.recordings, [
      {
        ...SyncRowCodec.recording(recording(id: 'a', title: 'theirs', summary: 'base')),
        'version': 2,
      },
    ]);
    advance(const Duration(minutes: 1));
    final r = await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'mine', summary: 'mine')]),
    );
    expect(r.conflicts, 1);
    expect(applier.recordings['a']!.title, 'theirs');
    expect(applier.recordings['a']!.summary, 'base');
    expect(
      applier.revisions.map((x) => (x.field, x.from, x.source)),
      containsAll([
        ('title', 'mine', RevisionSource.sync),
        ('summary', 'mine', RevisionSource.sync),
      ]),
    );
  });

  test('a pulled tombstone deletes through the callback; a dirty local writes revisions first', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'base')]));
    await transport.push(SyncTable.recordings, [
      {'id': 'a', 'version': 2, 'deleted_at': t0.toIso8601String()},
    ]);
    advance(const Duration(minutes: 1));
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'mine')]));
    expect(r.tombstonesApplied, 1);
    expect(applier.deleted, ['a']);
    expect(applier.revisions.single.field, 'title');
    expect(bookkeeping.loadTable('recordings').containsKey('a'), isFalse);
  });

  test('transcript never shrinks: local kept, row re-pushed', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', transcript: 'one two')]));
    await transport.push(SyncTable.recordings, [
      {...SyncRowCodec.recording(recording(id: 'a', transcript: 'one')), 'version': 2},
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', transcript: 'one two')]));
    expect(applier.recordings['a']!.transcript, 'one two');
    expect(transport.tables[SyncTable.recordings]!['a']!['transcript'], 'one two');
    expect(transport.tables[SyncTable.recordings]!['a']!['version'], 3);
  });

  test('the lag window re-read is idempotent', () async {
    await seedServer(recording(id: 'a'));
    advance(const Duration(seconds: 45));
    await engine.run(const SyncSnapshot());
    applier.upserts.clear();
    advance(const Duration(seconds: 50)); // cursor - 30 s still covers the row
    await engine.run(SyncSnapshot(recordings: [applier.recordings['a']!]));
    expect(applier.upserts, isEmpty, reason: 'same row, same version, nothing to apply');
  });

  test('a row that fails to decode is skipped and counted', () async {
    transport.tables.putIfAbsent(SyncTable.recordings, () => {})['bad'] = {
      'id': 'bad',
      'updated_at': t0.toIso8601String(),
      'version': 1,
    };
    await seedServer(recording(id: 'good'));
    advance(const Duration(minutes: 1));
    final r = await engine.run(const SyncSnapshot());
    expect(r.skipped, 1);
    expect(r.pulled, 1);
    expect(applier.recordings.keys, ['good']);
  });

  test('the cursor advances to the newest updated_at seen', () async {
    await seedServer(recording(id: 'a'));
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(bookkeeping.cursor('recordings'), t0);
  });

  test('projects, clipboard items and revisions are pulled through the applier', () async {
    await transport.push(SyncTable.projects, [
      {...SyncRowCodec.project(project(id: 'p')), 'version': 1},
    ]);
    await transport.push(SyncTable.clipboardItems, [
      {...SyncRowCodec.clipboardItem(clipboardItem(id: 'c')), 'version': 1},
    ]);
    await transport.push(SyncTable.revisions, [
      SyncRowCodec.revision(revision(recordingId: 'a')),
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(applier.projects.keys, ['p']);
    expect(applier.clipboardItems.keys, ['c']);
    expect(applier.revisions.single.recordingId, 'a');
  });

  test('a pulled project is bookkept by its own hash, not the raw jsonb row', () async {
    // Simulates Postgres jsonb reordering `payload`'s nested keys on
    // storage: same content as SyncRowCodec.project(project(id: 'p')), but
    // the payload map's keys are in a different order than the codec
    // produces them.
    transport.tables.putIfAbsent(SyncTable.projects, () => {})['p'] = {
      'id': 'p',
      'name': 'Project p',
      'repository_path': '/tmp/p',
      'payload': <String, Object?>{
        'agentSettings': <String, Object?>{},
        'defaultAgent': null,
        'sessionName': null,
        'description': null,
      },
      'version': 1,
      'updated_at': t0.toIso8601String(),
    };
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    final pulled = applier.projects['p']!;
    advance(const Duration(minutes: 2));
    // Pushing back exactly what was just pulled must be a no-op: if
    // bookkeeping hashed the raw pulled row instead of re-encoding through
    // the codec, this would look locally dirty and get pushed again.
    final r = await engine.run(SyncSnapshot(projects: [pulled]));
    expect(r.pushed, 0);
    expect(transport.tables[SyncTable.projects]!['p']!['version'], 1);
  });

  test('the redirtied re-push does not tombstone other recordings', () async {
    await engine.run(SyncSnapshot(recordings: [
      recording(id: 'a', transcript: 'one two'),
      recording(id: 'b', title: 'other'),
    ]));
    await transport.push(SyncTable.recordings, [
      {...SyncRowCodec.recording(recording(id: 'a', transcript: 'one')), 'version': 2},
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(SyncSnapshot(recordings: [
      recording(id: 'a', transcript: 'one two'),
      recording(id: 'b', title: 'other'),
    ]));
    expect(transport.tables[SyncTable.recordings]!['b']!['deleted_at'], isNull);
    expect(transport.tables[SyncTable.recordings]!['b']!['version'], 1);
  });

  test('a repository write failure leaves bookkeeping untouched', () async {
    await seedServer(recording(id: 'a', title: 'srv'));
    advance(const Duration(minutes: 1));
    applier.throwOnUpsertRecordings = Exception('disk full');
    final r = await engine.run(const SyncSnapshot());
    expect(r.success, isFalse);
    expect(r.failureReason, contains('disk full'));
    expect(bookkeeping.loadTable('recordings'), isEmpty);
  });

  test('a repository write failure leaves no orphaned conflict revisions', () async {
    // A genuine conflict, so _applyRecordings actually builds a non-empty
    // `revisions` list — proving the ordering, not just that nothing ran.
    await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'base', summary: 'base')]),
    );
    await transport.push(SyncTable.recordings, [
      {
        ...SyncRowCodec.recording(recording(id: 'a', title: 'theirs', summary: 'base')),
        'version': 2,
      },
    ]);
    advance(const Duration(minutes: 1));
    applier.throwOnUpsertRecordings = Exception('disk full');
    final r = await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'mine', summary: 'mine')]),
    );
    expect(r.success, isFalse);
    expect(bookkeeping.loadTable('recordings')['a']!.serverVersion, 1);
    expect(applier.revisions, isEmpty);
  });

  test('a pulled revision already pushed by this device is not re-appended', () async {
    await engine.run(SyncSnapshot(revisions: [revision(recordingId: 'a')]));
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(applier.revisions, isEmpty);
  });

  test('the transcript rule does not get reported as an overwritten field', () async {
    await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'base', transcript: 'one two')]),
    );
    await transport.push(SyncTable.recordings, [
      {
        ...SyncRowCodec.recording(recording(id: 'a', title: 'theirs', transcript: 'one')),
        'version': 2,
      },
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(
      SyncSnapshot(recordings: [recording(id: 'a', title: 'mine', transcript: 'one two')]),
    );
    expect(applier.revisions.map((r) => r.field), ['title']);
  });

  test('a pulled project tombstone deletes through the callback', () async {
    await transport.push(SyncTable.projects, [
      {...SyncRowCodec.project(project(id: 'p')), 'version': 1},
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(applier.projects.containsKey('p'), isTrue);
    await transport.push(SyncTable.projects, [
      {'id': 'p', 'version': 2, 'deleted_at': t0.toIso8601String()},
    ]);
    advance(const Duration(minutes: 2));
    final r = await engine.run(const SyncSnapshot());
    expect(r.tombstonesApplied, 1);
    expect(applier.deletedProjects, ['p']);
    expect(applier.projects.containsKey('p'), isFalse);
    expect(bookkeeping.loadTable('projects').containsKey('p'), isFalse);
  });

  test('a pulled clipboard item tombstone deletes through the callback', () async {
    await transport.push(SyncTable.clipboardItems, [
      {...SyncRowCodec.clipboardItem(clipboardItem(id: 'c')), 'version': 1},
    ]);
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(applier.clipboardItems.containsKey('c'), isTrue);
    await transport.push(SyncTable.clipboardItems, [
      {'id': 'c', 'version': 2, 'deleted_at': t0.toIso8601String()},
    ]);
    advance(const Duration(minutes: 2));
    final r = await engine.run(const SyncSnapshot());
    expect(r.tombstonesApplied, 1);
    expect(applier.deletedClipboardItems, ['c']);
    expect(applier.clipboardItems.containsKey('c'), isFalse);
    expect(bookkeeping.loadTable('clipboard_items').containsKey('c'), isFalse);
  });

  test('a segments push conflict is adopted into bookkeeping, not repeated', () async {
    final rec = recordingWithSegments(id: 'a', segmentCount: 1);
    final seg = SyncRowCodec.segments(rec).single;
    // Another device already pushed this segment; this device's bookkeeping
    // is empty, so its own push of the identical content races it.
    await transport.push(SyncTable.segments, [{...seg, 'version': 1}]);
    final r1 = await engine.run(SyncSnapshot(recordings: [rec]));
    expect(r1.conflicts, 1);
    transport.pushes.clear();
    final r2 = await engine.run(SyncSnapshot(recordings: [rec]));
    expect(r2.conflicts, 0);
    expect(r2.pushed, 0);
    // Not just "no conflict" — no push attempt at all: the adopted hash
    // must equal what an unchanged local push computes, or this would push
    // (and succeed, since the server content genuinely did not change).
    expect(
      transport.pushes.where((p) => p.$1 == SyncTable.segments && p.$2.isNotEmpty),
      isEmpty,
    );
  });

  test(
    'devices and sync_state push conflicts adopt without a spurious re-push',
    () async {
      // Another device already pushed this device's own row, and a
      // sync_state cursor row for it, before bookkeeping here is populated —
      // same race as the segments test, but on the two tables whose server
      // row (`to_jsonb(t)`) carries columns this device never sends:
      // `devices.created_at`/`last_seen_at` and `sync_state.pushed_through`.
      await transport.push(SyncTable.devices, [
        {
          ...SyncRowCodec.device(id: 'dev', name: 'n', platform: 'linux'),
          'version': 1,
        },
      ]);
      await transport.push(SyncTable.syncState, [
        {
          'device_id': 'dev',
          'table_name': 'recordings',
          'pulled_through': null,
          'version': 1,
        },
      ]);
      const snapshot = SyncSnapshot(
        device: {'id': 'dev', 'name': 'n', 'platform': 'linux'},
      );
      final r1 = await engine.run(snapshot);
      expect(r1.conflicts, greaterThan(0));
      final int adoptedDeviceVersion =
          bookkeeping.loadTable('devices')['dev']!.serverVersion;
      final int adoptedSyncStateVersion =
          bookkeeping.loadTable('sync_state')['dev/recordings']!.serverVersion;
      transport.pushes.clear();
      final r2 = await engine.run(snapshot);
      expect(r2.conflicts, 0);
      expect(
        transport.pushes.where((p) => p.$1 == SyncTable.devices && p.$2.isNotEmpty),
        isEmpty,
      );
      // sync_state is diffed and re-pushed by the cursor mirror on every
      // run, but nothing pulled between run 1 and run 2 changed the cursor
      // it mirrors — so a correctly-projected adopted hash must equal what
      // that unchanged content pushes, meaning the row for this device/table
      // is not in run 2's batch at all, and its bookkept version is not
      // bumped even once (never mind a stray second bump).
      final devRecordingsRows = transport.pushes
          .where((p) => p.$1 == SyncTable.syncState)
          .expand((p) => p.$2)
          .where(
            (row) => row['device_id'] == 'dev' && row['table_name'] == 'recordings',
          );
      expect(devRecordingsRows, isEmpty);
      expect(
        bookkeeping.loadTable('devices')['dev']!.serverVersion,
        adoptedDeviceVersion,
      );
      expect(
        bookkeeping.loadTable('sync_state')['dev/recordings']!.serverVersion,
        adoptedSyncStateVersion,
      );
    },
  );

  test('cursors are mirrored to a sync_state row per table for this device', () async {
    await seedServer(recording(id: 'a'));
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot(device: {'id': 'dev', 'name': 'n', 'platform': 'linux'}));
    final rows = transport.tables[SyncTable.syncState]!;
    expect(rows.keys.toSet(), {
      'dev/projects',
      'dev/recordings',
      'dev/clipboard_items',
      'dev/revisions',
    });
    expect(
      rows['dev/recordings']!['pulled_through'],
      bookkeeping.cursor('recordings')!.toIso8601String(),
    );
  });
}

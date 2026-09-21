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

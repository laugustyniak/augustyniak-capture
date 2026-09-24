import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_transport.dart';

void main() {
  test('disabled transport throws at use, not at construction', () {
    const SyncTransport transport = DisabledSyncTransport();
    expect(() => transport.push(SyncTable.projects, const []), throwsStateError);
  });

  test('fake transport gates on version like the rpc', () async {
    final FakeSyncTransport fake = FakeSyncTransport();
    SyncPushResult r = await fake.push(SyncTable.projects, [
      {'id': 'p', 'name': 'a', 'version': 1},
    ]);
    expect(r.applied, 1);
    r = await fake.push(SyncTable.projects, [
      {'id': 'p', 'name': 'b', 'version': 3},
    ]);
    expect(r.applied, 0);
    expect(r.conflicts.single['version'], 1);
    expect(r.conflicts.single['name'], 'a');
  });

  test('fake transport pulls by updated_at with the lag window', () async {
    final FakeSyncTransport fake = FakeSyncTransport(
      clock: () => DateTime.utc(2026, 9, 21, 12, 0, 0),
    );
    await fake.push(SyncTable.projects, [{'id': 'p', 'name': 'a', 'version': 1}]);
    // Stamped at 12:00:00; a pull at 12:00:10 must not see it yet (30 s lag).
    fake.clock = () => DateTime.utc(2026, 9, 21, 12, 0, 10);
    expect((await fake.pull(SyncTable.projects, since: null, after: null, limit: 10)).rows, isEmpty);
    fake.clock = () => DateTime.utc(2026, 9, 21, 12, 1, 0);
    expect((await fake.pull(SyncTable.projects, since: null, after: null, limit: 10)).rows, hasLength(1));
  });

  test('fake transport inserts a new row at any version, not just 1', () async {
    final FakeSyncTransport fake = FakeSyncTransport();
    final SyncPushResult r = await fake.push(SyncTable.projects, [
      {'id': 'p', 'name': 'a', 'version': 5},
    ]);
    expect(r.applied, 1);
    expect(r.conflicts, isEmpty);
  });

  test('fake transport treats a repeated revisions push as a no-op, not a conflict', () async {
    final FakeSyncTransport fake = FakeSyncTransport();
    final Map<String, Object?> row = {
      'recording_id': 'r',
      'at': DateTime.utc(2026, 9, 21).toIso8601String(),
      'field': 'title',
      'to_value': 'x',
    };
    SyncPushResult r = await fake.push(SyncTable.revisions, [row]);
    expect(r.applied, 1);
    r = await fake.push(SyncTable.revisions, [row]);
    expect(r.applied, 0);
    expect(r.conflicts, isEmpty);
  });

  test('a pulled timestamp with a non-zero fraction keeps it, trimming only trailing zeros', () async {
    final FakeSyncTransport fake = FakeSyncTransport(
      clock: () => DateTime.utc(2026, 9, 21, 12, 0, 0, 120),
    );
    await fake.push(SyncTable.projects, [{'id': 'p', 'name': 'a', 'version': 1}]);
    fake.clock = () => DateTime.utc(2026, 9, 21, 12, 1, 0);
    final rows = (await fake.pull(SyncTable.projects, since: null, after: null, limit: 10)).rows;
    expect(rows.single['updated_at'], '2026-09-21T12:00:00.12+00:00');
  });

  test('SyncPushResult defaults rejected to empty and the fake never rejects', () async {
    final FakeSyncTransport fake = FakeSyncTransport();
    final SyncPushResult r = await fake.push(SyncTable.projects, [
      {'id': 'p', 'name': 'a', 'version': 1},
    ]);
    expect(r.rejected, isEmpty);
  });

  test('fake transport keyset-pages rows that tie on updated_at and differ on a timestamp key', () async {
    final FakeSyncTransport fake = FakeSyncTransport(clock: () => DateTime.utc(2026, 9, 21, 12));
    await fake.push(SyncTable.revisions, [
      for (final int hour in <int>[7, 8])
        {
          'recording_id': 'r',
          'at': DateTime.utc(2026, 9, 21, hour).toIso8601String(),
          'field': 'title',
          'to_value': 'x',
        },
    ]);
    fake.clock = () => DateTime.utc(2026, 9, 21, 12, 1);
    final List<Object?> seen = <Object?>[];
    Map<String, Object?>? after;
    for (int pages = 0; pages < 5; pages++) {
      final SyncPage page = await fake.pull(SyncTable.revisions, since: null, after: after, limit: 1);
      seen.addAll(page.rows.map((Map<String, Object?> r) => r['at']));
      if (!page.hasMore || page.rows.isEmpty) break;
      after = page.rows.last;
    }
    expect(seen, <Object?>['2026-09-21T07:00:00+00:00', '2026-09-21T08:00:00+00:00']);
  });
}


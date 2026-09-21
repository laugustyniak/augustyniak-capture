import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_transport.dart';
import 'sync_fixtures.dart';

/// Wraps a [FakeSyncTransport] and pulls one row per push out of `applied`
/// into `rejected`, by row id — standing in for a `sync_push` row that
/// failed its own insert/update (a bad cast, a missing not-null column).
class _RejectingTransport implements SyncTransport {
  _RejectingTransport(this._inner, this.rejectId);
  final FakeSyncTransport _inner;
  final String rejectId;

  @override
  Future<SyncPushResult> push(
    SyncTable table,
    List<Map<String, Object?>> rows,
  ) async {
    final List<Map<String, Object?>> toApply = <Map<String, Object?>>[];
    final List<Map<String, Object?>> toReject = <Map<String, Object?>>[];
    for (final Map<String, Object?> row in rows) {
      (SyncRowCodec.rowId(table, row) == rejectId ? toReject : toApply).add(row);
    }
    final SyncPushResult result = await _inner.push(table, toApply);
    return SyncPushResult(
      applied: result.applied,
      conflicts: result.conflicts,
      rejected: toReject,
    );
  }

  @override
  Future<SyncPage> pull(
    SyncTable table, {
    required DateTime? since,
    required int offset,
    required int limit,
  }) => _inner.pull(table, since: since, offset: offset, limit: limit);

  @override
  Future<DateTime> serverNow() => _inner.serverNow();
}

void main() {
  late FakeSyncTransport transport;
  late MemoryBookkeeping bookkeeping;
  late SyncEngine engine;

  setUp(() {
    transport = FakeSyncTransport(clock: () => DateTime.utc(2026, 9, 21, 12));
    bookkeeping = MemoryBookkeeping();
    engine = SyncEngine(
      transport: transport,
      bookkeeping: bookkeeping,
      applier: NoopApplier(),
    );
  });

  test('a new recording is pushed at version 1 and remembered', () async {
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a')]));
    expect(r.pushed, 1);
    expect(transport.tables[SyncTable.recordings]!['a']!['version'], 1);
    expect(bookkeeping.loadTable('recordings')['a']!.serverVersion, 1);
  });

  test('an unchanged recording is not pushed again', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a')]));
    transport.pushes.clear();
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a')]));
    expect(r.pushed, 0);
    expect(
      transport.pushes.where((p) => p.$1 == SyncTable.recordings && p.$2.isNotEmpty),
      isEmpty,
    );
  });

  test('an edited recording is pushed at the next version', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'one')]));
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'two')]));
    expect(transport.tables[SyncTable.recordings]!['a']!['version'], 2);
    expect(transport.tables[SyncTable.recordings]!['a']!['title'], 'two');
  });

  test('a recording gone from the snapshot becomes a tombstone', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a')]));
    final r = await engine.run(const SyncSnapshot(recordings: []));
    expect(r.pushed, 1);
    expect(transport.tables[SyncTable.recordings]!['a']!['deleted_at'], isNotNull);
    expect(transport.tables[SyncTable.recordings]!['a']!['version'], 2);
    expect(bookkeeping.loadTable('recordings').containsKey('a'), isFalse);
  });

  test('a stale push is counted as a conflict and the version is not advanced', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'one')]));
    // Another device moved the server row to version 2.
    await transport.push(SyncTable.recordings, [
      {...SyncRowCodec.recording(recording(id: 'a', title: 'theirs')), 'version': 2},
    ]);
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'mine')]));
    expect(r.conflicts, 1);
    expect(transport.tables[SyncTable.recordings]!['a']!['title'], 'theirs');
  });

  test('segments and revisions ride with the recording', () async {
    final rec = recordingWithSegments(id: 'a', segmentCount: 2);
    final r = await engine.run(
      SyncSnapshot(recordings: [rec], revisions: [revision(recordingId: 'a')]),
    );
    expect(transport.tables[SyncTable.segments]!.length, 2);
    expect(transport.tables[SyncTable.revisions]!.length, 1);
    expect(r.pushed, 4);
  });

  test('a transport failure reports a reason and changes no bookkeeping', () async {
    transport.failWith = Exception('boom');
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a')]));
    expect(r.success, isFalse);
    expect(r.failureReason, contains('boom'));
    expect(bookkeeping.loadTable('recordings'), isEmpty);
  });

  test('a rejected row is skipped: withheld from bookkeeping, tallied, not applied', () async {
    final rejecting = _RejectingTransport(transport, 'bad');
    final rejectingEngine = SyncEngine(
      transport: rejecting,
      bookkeeping: bookkeeping,
      applier: NoopApplier(),
    );
    final r = await rejectingEngine.run(
      SyncSnapshot(recordings: [recording(id: 'good'), recording(id: 'bad')]),
    );
    expect(r.skipped, 1);
    expect(r.pushed, 1);
    expect(bookkeeping.loadTable('recordings').containsKey('bad'), isFalse);
    expect(bookkeeping.loadTable('recordings').containsKey('good'), isTrue);
  });

  test('pushes are batched at 200 rows', () async {
    final rows = [for (int i = 0; i < 450; i++) clipboardItem(id: 'c$i')];
    await engine.run(SyncSnapshot(clipboardItems: rows));
    final batches = transport.pushes.where((p) => p.$1 == SyncTable.clipboardItems).toList();
    expect(batches.map((b) => b.$2.length), [200, 200, 50]);
  });
}

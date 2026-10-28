import 'dart:io';

import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/data/repository_sync_applier.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';
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
      syncClipboard: true,
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
    expect(applier.deletedWithHold, [('a', false)]);
    expect(r.tombstonesHeld, 0);
    expect(applier.revisions.single.field, 'title');
    expect(bookkeeping.loadTable('recordings').containsKey('a'), isFalse);
  });

  group('blast-radius cap on pulled recording tombstones (#304)', () {
    Future<SupabaseSyncResult> pullTombstones({
      required int serverDeletes,
      required int localPresent,
    }) async {
      final List<Recording> mine = <Recording>[
        for (int i = 0; i < serverDeletes; i++)
          if (i < localPresent) recording(id: 'r$i', title: 't'),
      ];
      // Everything is on the server first, so each tombstone is a version bump.
      await engine.run(
        SyncSnapshot(
          recordings: <Recording>[
            for (int i = 0; i < serverDeletes; i++) recording(id: 'r$i', title: 't'),
          ],
        ),
      );
      await transport.push(SyncTable.recordings, [
        for (int i = 0; i < serverDeletes; i++)
          {'id': 'r$i', 'version': 2, 'deleted_at': t0.toIso8601String()},
      ]);
      advance(const Duration(minutes: 1));
      // Bookkeeping says these were pushed; locally only [mine] still exist.
      return engine.run(SyncSnapshot(recordings: mine));
    }

    test('more than the threshold present locally: every delete is held', () async {
      final r = await pullTombstones(serverDeletes: 11, localPresent: 11);
      expect(r.tombstonesApplied, 11);
      expect(r.tombstonesHeld, 11);
      expect(applier.deletedWithHold, hasLength(11));
      expect(applier.deletedWithHold.every(((String, bool) e) => e.$2), isTrue);
    });

    test('exactly the threshold present locally: not held', () async {
      final r = await pullTombstones(serverDeletes: 10, localPresent: 10);
      expect(r.tombstonesApplied, 10);
      expect(r.tombstonesHeld, 0);
      expect(applier.deletedWithHold.any(((String, bool) e) => e.$2), isFalse);
    });

    test('tombstones for rows this device never had do not count', () async {
      final r = await pullTombstones(serverDeletes: 11, localPresent: 3);
      expect(r.tombstonesApplied, 3);
      expect(r.tombstonesHeld, 0);
      expect(applier.deletedWithHold.any(((String, bool) e) => e.$2), isFalse);
    });

    test('the budget spans push-conflict rows and pulled rows in one run', () async {
      Recording rec(String id, String title) => recording(id: id, title: title);
      final List<String> conflictIds = <String>[for (int i = 0; i < 6; i++) 'c$i'];
      final List<String> pulledIds = <String>[for (int i = 0; i < 6; i++) 'p$i'];
      final List<String> all = <String>[...conflictIds, ...pulledIds];
      await engine.run(
        SyncSnapshot(recordings: <Recording>[for (final String id in all) rec(id, 't')]),
      );
      await transport.push(SyncTable.recordings, [
        for (final String id in all)
          {'id': id, 'version': 2, 'deleted_at': t0.toIso8601String()},
      ]);
      advance(const Duration(minutes: 1));
      // The c* rows were edited here too, so their push meets the server's
      // tombstone as a conflict; the p* rows arrive as ordinary pulled rows.
      final r = await engine.run(
        SyncSnapshot(
          recordings: <Recording>[
            for (final String id in conflictIds) rec(id, 'edited'),
            for (final String id in pulledIds) rec(id, 't'),
          ],
        ),
      );

      expect(r.conflicts, 6);
      expect(r.tombstonesApplied, 12);
      // 6 <= 10 in the conflict batch: not held, and not retroactively held.
      // The pull then brings the run's total to 12 > 10: its 6 are held.
      expect(r.tombstonesHeld, 6);
      expect(
        applier.deletedWithHold.where(((String, bool) e) => e.$1.startsWith('c')).any(((String, bool) e) => e.$2),
        isFalse,
      );
      expect(
        applier.deletedWithHold.where(((String, bool) e) => e.$1.startsWith('p')).every(((String, bool) e) => e.$2),
        isTrue,
      );
    });

    test('the count starts over on the next run', () async {
      await pullTombstones(serverDeletes: 6, localPresent: 6);
      applier.deletedWithHold.clear();
      // A second run with another 6 present tombstones: a slow drip of
      // fewer than ten a run is deliberately not covered.
      await engine.run(SyncSnapshot(recordings: <Recording>[]));
      final r = await pullTombstones(serverDeletes: 6, localPresent: 6);
      expect(r.tombstonesHeld, 0);
    });

    test('the threshold is a constructor parameter', () async {
      engine = SyncEngine(
        transport: transport,
        bookkeeping: bookkeeping,
        applier: applier,
        clock: () => t0,
        tombstoneHoldThreshold: 2,
      );
      final r = await pullTombstones(serverDeletes: 3, localPresent: 3);
      expect(r.tombstonesHeld, 3);
    });
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

  test(
    'the cursor holds at a skipped row older than the newest one, and '
    're-offers it next run — finding 8',
    () async {
      // A row this build cannot decode (no created_at) — the oldest in
      // this page.
      transport.tables.putIfAbsent(SyncTable.recordings, () => {})['bad'] = {
        'id': 'bad',
        'updated_at': t0.toIso8601String(),
        'version': 1,
      };
      // A decodable row, newer than the skipped one, same page.
      advance(const Duration(seconds: 10));
      await seedServer(recording(id: 'good'));

      advance(const Duration(minutes: 1));
      final r1 = await engine.run(const SyncSnapshot());
      expect(r1.skipped, 1);
      expect(r1.pulled, 1);
      // Must not advance past the skipped row's own stamp just because a
      // newer, decodable row was seen in the same page.
      expect(bookkeeping.cursor('recordings'), t0);

      // Next run still offers the skipped row (its stamp is inside the
      // window again) and skips it again — proving it was re-pulled, not
      // silently dropped.
      advance(const Duration(minutes: 1));
      final r2 = await engine.run(const SyncSnapshot());
      expect(r2.skipped, 1);
    },
  );

  test(
    'a row still carrying an E2EE envelope is skipped, holds the cursor and '
    're-offers, never applied blank — #298',
    () async {
      // No cipher in this pipeline (or one that could not open it): the row
      // arrives with the server's nulls and the envelope still on it.
      transport.tables.putIfAbsent(SyncTable.recordings, () => {})['sealed'] = {
        ...SyncRowCodec.recording(recording(id: 'sealed', title: 'must not land')),
        'title': null,
        'transcript': null,
        'encrypted_payload': 'enc:v2:AAAA',
        'updated_at': t0.toIso8601String(),
        'version': 1,
      };
      advance(const Duration(seconds: 10));
      await seedServer(recording(id: 'good'));

      advance(const Duration(minutes: 1));
      final r1 = await engine.run(const SyncSnapshot());
      expect(r1.skipped, 1);
      expect(r1.pulled, 1);
      expect(applier.recordings.keys, ['good'], reason: 'a sealed row is never applied as a blank');
      expect(bookkeeping.cursor('recordings'), t0, reason: 'held at the sealed row');

      // Terminates and re-offers: the row is still in the page the engine
      // pages after, so the run ends, and the next run sees it again.
      advance(const Duration(minutes: 1));
      final r2 = await engine.run(const SyncSnapshot());
      expect(r2.skipped, 1);
      expect(applier.recordings.keys, ['good']);
    },
  );

  test('a tombstone that still carries an envelope is applied as a delete, not skipped', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'v1')]));
    transport.tables[SyncTable.recordings]!['a'] = {
      'id': 'a',
      'version': 2,
      'deleted_at': t0.toIso8601String(),
      'encrypted_payload': 'enc:v2:AAAA',
      'updated_at': t0.add(const Duration(seconds: 10)).toIso8601String(),
    };
    advance(const Duration(minutes: 1));
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'v1')]));
    expect(r.tombstonesApplied, 1);
    expect(r.skipped, 0);
    expect(applier.deleted, contains('a'));
  });

  test('a sealed revision row is skipped and holds the revisions cursor', () async {
    transport.tables.putIfAbsent(SyncTable.revisions, () => {})['rec-1/x/title'] = {
      'recording_id': 'rec-1',
      'at': t0.toIso8601String(),
      'field': 'title',
      'from_value': null,
      'to_value': null,
      'source': 'user',
      'encrypted_payload': 'enc:v2:AAAA',
      'updated_at': t0.toIso8601String(),
    };
    advance(const Duration(minutes: 1));
    final r = await engine.run(const SyncSnapshot());
    expect(r.skipped, 1);
    expect(applier.revisions, isEmpty);
    expect(bookkeeping.cursor('revisions'), t0);
  });

  test(
    'a row whose id is not a safe path segment is dropped, counted, never '
    'applied, and does not hold the cursor (#292)',
    () async {
      // Oldest on the page, so a cursor held at it would sit at t0.
      transport.tables.putIfAbsent(SyncTable.recordings, () => {})['..'] = {
        ...SyncRowCodec.recording(recording(id: '..')),
        'updated_at': t0.toIso8601String(),
        'version': 1,
      };
      // A tombstone with an unsafe id must not reach the applier's delete.
      transport.tables[SyncTable.recordings]!['../x'] = {
        'id': '../x',
        'updated_at': t0.toIso8601String(),
        'version': 2,
        'deleted_at': t0.toIso8601String(),
      };
      advance(const Duration(seconds: 10));
      await seedServer(recording(id: 'good'));

      advance(const Duration(minutes: 1));
      final r = await engine.run(const SyncSnapshot());
      expect(r.skipped, 2);
      expect(r.pulled, 1);
      expect(applier.recordings.keys, ['good']);
      expect(applier.deleted, isEmpty);
      expect(
        bookkeeping.cursor('recordings'),
        t0.add(const Duration(seconds: 10)),
        reason: 'no build can ever decode the row, so it must not pin the cursor',
      );
    },
  );

  for (final SyncTable table in <SyncTable>[SyncTable.projects, SyncTable.clipboardItems]) {
    test(
      '${table.serverName}: unsafe ids are dropped, live or tombstone, and do '
      'not hold the cursor (#292)',
      () async {
        final bool isProject = table == SyncTable.projects;
        Map<String, Object?> encoded(String id) => isProject
            ? SyncRowCodec.project(project(id: id))
            : SyncRowCodec.clipboardItem(clipboardItem(id: id));
        final Map<String, Map<String, Object?>> rows =
            transport.tables.putIfAbsent(table, () => {});
        rows['..'] = {
          ...encoded('..'),
          'updated_at': t0.toIso8601String(),
          'version': 1,
        };
        rows['../x'] = {
          'id': '../x',
          'updated_at': t0.toIso8601String(),
          'version': 2,
          'deleted_at': t0.toIso8601String(),
        };
        advance(const Duration(seconds: 10));
        await transport.push(table, [
          {...encoded('good'), 'version': 1},
        ]);

        advance(const Duration(minutes: 1));
        final r = await engine.run(const SyncSnapshot());
        expect(r.skipped, 2);
        expect(r.pulled, 1);
        expect(
          isProject ? applier.projects.keys : applier.clipboardItems.keys,
          ['good'],
        );
        expect(applier.deletedProjects, isEmpty);
        expect(applier.deletedClipboardItems, isEmpty);
        expect(
          bookkeeping.cursor(table.serverName),
          t0.add(const Duration(seconds: 10)),
        );
      },
    );
  }

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

  test('clipboard sync off: clipboard rows are not pulled and no cursor moves',
      () async {
    await transport.push(SyncTable.clipboardItems, [
      {...SyncRowCodec.clipboardItem(clipboardItem(id: 'c')), 'version': 1},
    ]);
    await seedServer(recording(id: 'a'));
    advance(const Duration(minutes: 1));
    final SyncEngine off = SyncEngine(
      transport: transport,
      bookkeeping: bookkeeping,
      applier: applier,
      clock: () => t0,
    );

    await off.run(
      const SyncSnapshot(device: {'id': 'dev', 'name': 'n', 'platform': 'linux'}),
    );

    expect(applier.clipboardItems, isEmpty);
    expect(bookkeeping.cursor('clipboard_items'), isNull);
    expect(applier.recordings.keys, ['a']);
    expect(
      transport.tables[SyncTable.syncState]!.keys.toSet(),
      {'dev/projects', 'dev/recordings', 'dev/revisions'},
    );
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

  test(
    'a pulled clipboard item matching the newest local one lands through '
    'the real repository, and the next run pushes no tombstone for it',
    () async {
      // Finding 1: `ClipboardRepository.addItem`'s adjacent-content dedupe
      // used to drop a pulled row identical to the newest local entry while
      // `RepositorySyncApplier` still bookkept it as applied — so the next
      // run's outbox was missing the id and the sweep tombstoned it. Real
      // applier and real repository here, not the `RecordingApplier` fake
      // the rest of this file uses, because the bug lived in that seam.
      final Directory dir = await Directory.systemTemp.createTemp(
        'augustyniak-capture-clipboard-dedupe-tombstone-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final ClipboardRepository clipboard = LocalJsonClipboardRepository(
        storageDirectoryProvider: () async => dir,
      );
      await clipboard.addItem(
        ClipboardItem(
          id: 'local-1',
          type: ClipboardItemType.text,
          text: 'same text',
          copiedAt: DateTime.utc(2026, 9, 21, 7),
        ),
      );

      final RepositorySyncApplier realApplier = RepositorySyncApplier(
        applySyncedRecordings: (List<Recording> _) async {},
        applySyncedProjects: (List<Project> _) async {},
        applySyncedProjectDelete: (String _) async {},
        clipboard: clipboard,
        revisions: null,
        applySyncedRecordingDelete: (String _, {required bool hold}) async {},
        recordingExists: (String _) => false,
      );
      final SyncEngine realEngine = SyncEngine(
        transport: transport,
        bookkeeping: bookkeeping,
        applier: realApplier,
        clock: () => t0,
        syncClipboard: true,
      );

      await transport.push(SyncTable.clipboardItems, [
        {
          ...SyncRowCodec.clipboardItem(
            ClipboardItem(
              id: 'pulled-1',
              type: ClipboardItemType.text,
              text: 'same text',
              copiedAt: DateTime.utc(2026, 9, 21, 7, 30),
            ),
          ),
          'version': 1,
        },
      ]);
      advance(const Duration(minutes: 1));
      await realEngine.run(const SyncSnapshot());

      final List<ClipboardItem> afterPull = await clipboard.getItems();
      expect(
        afterPull.map((ClipboardItem c) => c.id),
        containsAll(<String>['local-1', 'pulled-1']),
        reason: 'the dedupe drop must not cost the pulled item',
      );

      advance(const Duration(minutes: 2));
      final SupabaseSyncResult r2 = await realEngine.run(
        SyncSnapshot(clipboardItems: afterPull),
      );
      expect(r2.tombstonesApplied, 0);
      expect(
        transport.tables[SyncTable.clipboardItems]!['pulled-1']!['deleted_at'],
        isNull,
      );
    },
  );

  test('a row another device updates between two pages does not skip the next row', () async {
    // #195: three rows, two per page. Between the pages another device
    // bumps `a`, which moves it past the window; offset paging then asks
    // for "rows 3.." of a list that is now only two long and loses `c`.
    for (final (int i, String id) in <(int, String)>[(0, 'a'), (1, 'b'), (2, 'c')]) {
      advance(Duration(seconds: i));
      await seedServer(recording(id: id, title: id));
    }
    advance(const Duration(minutes: 1));
    engine = SyncEngine(
      transport: transport,
      bookkeeping: bookkeeping,
      applier: applier,
      clock: () => t0,
      pageSize: 2,
    );
    int recordingPulls = 0;
    transport.beforePull = (SyncTable table) async {
      if (table != SyncTable.recordings || ++recordingPulls != 2) return;
      await transport.push(SyncTable.recordings, [
        {...SyncRowCodec.recording(recording(id: 'a', title: 'a2')), 'version': 2},
      ]);
    };

    await engine.run(const SyncSnapshot());

    expect(applier.recordings.keys, containsAll(<String>['a', 'b', 'c']));
  });

  group('a row last seen sealed is refused when it arrives unsealed (#377)', () {
    final Recording local = recording(id: 'a', transcript: 'sealed text');
    final String localHash = SyncRowCodec.hash(SyncRowCodec.recording(local));

    Future<void> seedNewer({required bool marker}) => transport.push(
      SyncTable.recordings,
      [
        {
          ...SyncRowCodec.recording(
            recording(id: 'a', transcript: 'sealed text, edited by the server'),
          ),
          'version': 2,
          if (marker) syncRowSealedMarker: true,
        },
      ],
    );

    test('an unmarked row for a sealed id is counted, not applied or bookkept', () async {
      bookkeeping.put('recordings', 'a', 1, localHash, sealed: true);
      await seedNewer(marker: false);
      advance(const Duration(minutes: 1));

      final r = await engine.run(SyncSnapshot(recordings: [local]));

      expect(r.downgraded, 1);
      expect(r.pulled, 0);
      expect(applier.recordings, isEmpty);
      final SyncRowState state = bookkeeping.loadTable('recordings')['a']!;
      expect(state.serverVersion, 1);
      expect(state.pushedHash, localHash);
      expect(state.sealed, isTrue);
    });

    test('the same row carrying the marker applies and stays sealed', () async {
      bookkeeping.put('recordings', 'a', 1, localHash, sealed: true);
      await seedNewer(marker: true);
      advance(const Duration(minutes: 1));

      final r = await engine.run(SyncSnapshot(recordings: [local]));

      expect(r.downgraded, 0);
      expect(r.pulled, 1);
      expect(applier.recordings['a']!.transcript, 'sealed text, edited by the server');
      final SyncRowState state = bookkeeping.loadTable('recordings')['a']!;
      expect(state.serverVersion, 2);
      expect(state.sealed, isTrue);
    });

    test('a legacy row (bookkept unsealed) still applies unmarked', () async {
      bookkeeping.put('recordings', 'a', 1, localHash);
      await seedNewer(marker: false);
      advance(const Duration(minutes: 1));

      final r = await engine.run(SyncSnapshot(recordings: [local]));

      expect(r.downgraded, 0);
      expect(r.pulled, 1);
      expect(applier.recordings['a']!.transcript, 'sealed text, edited by the server');
      expect(bookkeeping.loadTable('recordings')['a']!.sealed, isFalse);
    });

    test('a still-sealed row for a sealed id is skipped and holds the cursor, not counted as downgraded', () async {
      bookkeeping.put('recordings', 'a', 1, localHash, sealed: true);
      transport.tables.putIfAbsent(SyncTable.recordings, () => {})['a'] = {
        ...SyncRowCodec.recording(local),
        'title': null,
        'transcript': null,
        'encrypted_payload': 'enc:v2:AAAA',
        'updated_at': t0.toIso8601String(),
        'version': 2,
      };
      advance(const Duration(minutes: 1));

      final r = await engine.run(SyncSnapshot(recordings: [local]));

      expect(r.skipped, 1);
      expect(r.downgraded, 0);
      expect(applier.recordings, isEmpty);
      expect(bookkeeping.cursor('recordings'), t0, reason: 'held at the sealed row');
      final SyncRowState state = bookkeeping.loadTable('recordings')['a']!;
      expect(state.serverVersion, 1);
      expect(state.sealed, isTrue);
    });

    test('an unmarked push-conflict row for a sealed id is refused, the local row stays dirty', () async {
      final Recording v1 = recording(id: 'a', transcript: 'v1');
      bookkeeping.put(
        'recordings',
        'a',
        1,
        SyncRowCodec.hash(SyncRowCodec.recording(v1)),
        sealed: true,
      );
      await transport.push(SyncTable.recordings, [
        {
          ...SyncRowCodec.recording(recording(id: 'a', transcript: 'server edit')),
          'version': 2,
        },
      ]);

      final r = await engine.run(
        SyncSnapshot(recordings: [recording(id: 'a', transcript: 'local edit')]),
      );

      expect(r.conflicts, 1);
      expect(r.downgraded, 1);
      expect(applier.recordings, isEmpty);
      final SyncRowState state = bookkeeping.loadTable('recordings')['a']!;
      expect(state.serverVersion, 1);
      expect(state.sealed, isTrue);
    });

    test('adopting a segments push conflict keeps the sealed flag', () async {
      final rec = recordingWithSegments(id: 'a', segmentCount: 1);
      final seg = SyncRowCodec.segments(rec).single;
      await transport.push(SyncTable.segments, [{...seg, 'version': 1}]);
      bookkeeping.put('segments', 'a/0', 0, 'stale', sealed: true);

      final r = await engine.run(SyncSnapshot(recordings: [rec]));

      expect(r.conflicts, greaterThanOrEqualTo(1));
      final SyncRowState state = bookkeeping.loadTable('segments')['a/0']!;
      expect(state.serverVersion, 1);
      expect(state.sealed, isTrue);
    });

    test('a project last seen sealed is refused when it arrives unmarked', () async {
      final Project mine = project(id: 'p');
      final String hash = SyncRowCodec.hash(SyncRowCodec.project(mine));
      bookkeeping.put('projects', 'p', 1, hash, sealed: true);
      await transport.push(SyncTable.projects, [
        {
          ...SyncRowCodec.project(Project(id: 'p', name: 'Renamed by server', repoPath: '/evil')),
          'version': 2,
        },
      ]);
      advance(const Duration(minutes: 1));

      final r = await engine.run(SyncSnapshot(projects: [mine]));

      expect(r.downgraded, 1);
      expect(r.pulled, 0);
      expect(applier.projects, isEmpty);
      expect(bookkeeping.loadTable('projects')['p']!.serverVersion, 1);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/data/supabase_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_fixtures.dart';

/// End-to-end run against a real, locally running Supabase stack
/// (`supabase start`, migrations applied) — the only test in the suite that
/// touches a network. Skipped unless all three env vars below are set, so
/// the default `flutter test` run stays green and fast and never
/// constructs a client.
///
///   SUPABASE_E2E_URL              e.g. http://127.0.0.1:54321
///   SUPABASE_E2E_ANON_KEY         `supabase status -o json` .ANON_KEY
///   SUPABASE_E2E_SERVICE_ROLE_KEY `supabase status -o json` .SERVICE_ROLE_KEY
///
/// The scenario needs **two** recordings on device A (`x`, the row every
/// assertion below is about, and `y`, an inert anchor) rather than the one
/// the task brief sketches. `SyncEngine._pushTable` refuses — rather than
/// sweeping — a push whose outbox for a table has gone entirely empty while
/// that device's bookkeeping for the table is not (`docs/architecture/sync.md`
/// "The engine fuse", exercised by `sync_engine_push_test.dart`'s "two rows,
/// not one" tombstone test). A single-recording device can therefore never
/// produce the tombstone this test needs: dropping its only row from the
/// snapshot trips the fuse instead of pushing a tombstone. `y` stays
/// untouched through the whole run purely so the outbox is never empty.
///
/// Each engine also carries its own `device:` row (per the addendum's
/// "each engine instance gets its own device row with a distinct id"), so
/// the `devices` table and the `sync_state` cursor mirror in `_pullAll` are
/// exercised against the real RPC too — that combination is exactly what
/// surfaced the bug this test's own report documents. A device row is only
/// ever new on that engine's first call, so it adds exactly one to that
/// call's `pushed` and is otherwise invisible to every count below.
///
/// Both of these shift a couple of counts away from the brief's literal
/// numbers (documented at each assertion below); the report explains it.
void main() {
  final String? url = Platform.environment['SUPABASE_E2E_URL'];
  final String? anonKey = Platform.environment['SUPABASE_E2E_ANON_KEY'];
  final String? serviceRoleKey = Platform.environment['SUPABASE_E2E_SERVICE_ROLE_KEY'];
  final bool ready = url != null && anonKey != null && serviceRoleKey != null;

  group('sync engine against the local supabase stack', () {
    late SupabaseClient clientA;
    late SupabaseClient clientB;

    setUpAll(() async {
      final String suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final String emailA = 'e2e-a-$suffix@example.com';
      final String emailB = 'e2e-b-$suffix@example.com';
      await _createUser(url!, serviceRoleKey!, emailA, 'password-a-$suffix');
      await _createUser(url, serviceRoleKey, emailB, 'password-b-$suffix');

      clientA = SupabaseClient(url, anonKey!);
      clientB = SupabaseClient(url, anonKey);
      await clientA.auth.signInWithPassword(email: emailA, password: 'password-a-$suffix');
      await clientB.auth.signInWithPassword(email: emailB, password: 'password-b-$suffix');
    });

    tearDownAll(() async {
      await clientA.dispose();
      await clientB.dispose();
    });

    test(
      'push, RLS-scoped pull, conflict and tombstone all round-trip through '
      'the real sync_push/pull RPCs',
      () async {
        final String suffix = DateTime.now().microsecondsSinceEpoch.toString();
        final String x = 'e2e-x-$suffix';
        final String y = 'e2e-y-$suffix';

        // Each engine instance is its own device, wired with its own
        // `devices` row so the `devices` upsert and the `sync_state`
        // cursor mirror in `_pullAll` (composite key device_id/table_name)
        // exercise the real RPC too, not just recordings.
        final Map<String, Object?> deviceA1 = SyncRowCodec.device(
          id: 'e2e-a1-$suffix',
          name: 'a1',
          platform: 'test',
        );
        final Map<String, Object?> deviceA2 = SyncRowCodec.device(
          id: 'e2e-a2-$suffix',
          name: 'a2',
          platform: 'test',
        );
        final Map<String, Object?> deviceB1 = SyncRowCodec.device(
          id: 'e2e-b1-$suffix',
          name: 'b1',
          platform: 'test',
        );

        final MemoryBookkeeping bkA1 = MemoryBookkeeping();
        final RecordingApplier apA1 = RecordingApplier();
        final SyncEngine a1 = SyncEngine(
          transport: SupabaseSyncTransport(clientA),
          bookkeeping: bkA1,
          applier: apA1,
        );
        final MemoryBookkeeping bkA2 = MemoryBookkeeping();
        final RecordingApplier apA2 = RecordingApplier();
        final SyncEngine a2 = SyncEngine(
          transport: SupabaseSyncTransport(clientA),
          bookkeeping: bkA2,
          applier: apA2,
        );
        final SyncEngine b1 = SyncEngine(
          transport: SupabaseSyncTransport(clientB),
          bookkeeping: MemoryBookkeeping(),
          applier: RecordingApplier(),
        );

        // Step 1: A1 pushes both rows plus its own device row. `x` is the
        // brief's "one recording"; `y` is the anchor described above —
        // pushed == 3 (x, y, the device row), not the brief's 1, because
        // all three are new.
        final Map<String, Recording> a1Rows = <String, Recording>{
          x: recording(id: x, title: 'v1'),
          y: recording(id: y, title: 'anchor'),
        };
        final SupabaseSyncResult r1 = await a1.run(
          SyncSnapshot(recordings: a1Rows.values.toList(), device: deviceA1),
        );
        expect(r1.failureReason, isNull, reason: _describe(r1));
        expect(r1.pushed, 3, reason: _describe(r1));

        // Step 2: A2 (fresh bookkeeping, starting from an empty snapshot,
        // matching the brief) polls until it has pulled both rows. The lag
        // window (`syncLagWindow`, 30 s) means neither is visible
        // immediately, so this is a real poll, not a formality. Each
        // iteration's snapshot is rebuilt from the applier's own live
        // state (plus A2's device row) rather than held fixed empty: the
        // two rows share close `updated_at` timestamps but pagination is
        // not guaranteed to land them in the same page, and once one row
        // is bookkept while the outbox is still built from a stale empty
        // snapshot, the next call would trip the same empty-outbox fuse
        // step 1's doc comment describes. Checked against the applier's
        // cumulative state, for the same reason: a single call's `pulled`
        // might never show `== 2` even though both eventually arrive.
        final SupabaseSyncResult r2 = await _pollUntil(
          () => a2.run(
            SyncSnapshot(recordings: apA2.recordings.values.toList(), device: deviceA2),
          ),
          () => apA2.recordings.containsKey(x) && apA2.recordings.containsKey(y),
        );
        expect(r2.failureReason, isNull, reason: _describe(r2));
        expect(apA2.recordings[x]?.title, 'v1', reason: _describe(r2));
        expect(apA2.recordings[y]?.title, 'anchor', reason: _describe(r2));

        // Step 3: B1 (fresh, empty except its own device row, a different
        // owner) runs once, after A2's pull has already landed — so a 0
        // here is RLS row-level security, not just the lag window not
        // having elapsed yet. pushed == 1 is B1's own device row; RLS
        // means it can never see A's recordings, so 0 is pushed for those
        // regardless of the fuse (B1's own recordings bookkeeping is
        // empty, so nothing trips it).
        final SupabaseSyncResult r3 = await b1.run(SyncSnapshot(device: deviceB1));
        expect(r3.failureReason, isNull, reason: _describe(r3));
        expect(r3.pushed, 1, reason: _describe(r3));
        expect(r3.pulled, 0, reason: _describe(r3));

        // Step 4: conflict. A1 edits `x`'s title (pushed == 1: `y` is
        // unchanged and not re-pushed).
        a1Rows[x] = recording(id: x, title: 'a1-edit');
        final SupabaseSyncResult r4push = await a1.run(
          SyncSnapshot(recordings: a1Rows.values.toList(), device: deviceA1),
        );
        expect(r4push.failureReason, isNull, reason: _describe(r4push));
        expect(r4push.pushed, 1, reason: _describe(r4push));

        // A2 edits `x` to a different value from its own (stale, version-1)
        // copy. The push loses the version race immediately — no lag
        // window on push, so this is a single call, not a poll.
        apA2.recordings[x] = apA2.recordings[x]!.copyWith(title: 'a2-edit');
        final SupabaseSyncResult r4conflict = await a2.run(
          SyncSnapshot(recordings: apA2.recordings.values.toList(), device: deviceA2),
        );
        expect(r4conflict.conflicts, 1, reason: _describe(r4conflict));
        // `_resolvePushConflicts` applies the conflicting row through the
        // same path a pull would, so this counts as pulled too.
        expect(r4conflict.pulled, 1, reason: _describe(r4conflict));
        expect(apA2.recordings[x]?.title, 'a1-edit');
        expect(
          apA2.revisions.where(
            (rev) => rev.field == 'title' && rev.source == RevisionSource.sync && rev.from == 'a2-edit',
          ),
          isNotEmpty,
        );

        // Step 5: tombstone. A1 drops `x` from its snapshot — `y` stays, so
        // the outbox is not empty and the fuse does not trip; pushed == 1
        // (the tombstone).
        a1Rows.remove(x);
        final SupabaseSyncResult r5push = await a1.run(
          SyncSnapshot(recordings: a1Rows.values.toList(), device: deviceA1),
        );
        expect(r5push.failureReason, isNull, reason: _describe(r5push));
        expect(r5push.pushed, 1, reason: _describe(r5push));

        // A2 polls, still holding `x` (its own current, synced copy) and
        // `y` — rebuilt from the applier's live state each iteration, so a
        // row `y` A2 has not yet dropped is never swept out from under it
        // by a stale snapshot.
        final SupabaseSyncResult r5 = await _pollUntil(
          () => a2.run(
            SyncSnapshot(recordings: apA2.recordings.values.toList(), device: deviceA2),
          ),
          () => apA2.deleted.contains(x),
        );
        expect(r5.failureReason, isNull, reason: _describe(r5));
        expect(r5.tombstonesApplied, 1, reason: _describe(r5));
        expect(apA2.deleted, contains(x));
        expect(apA2.recordings.containsKey(x), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: ready ? false : 'set SUPABASE_E2E_URL, SUPABASE_E2E_ANON_KEY, SUPABASE_E2E_SERVICE_ROLE_KEY');
}

Future<void> _createUser(String url, String serviceRoleKey, String email, String password) async {
  final http.Response response = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: <String, String>{
      'apikey': serviceRoleKey,
      'Authorization': 'Bearer $serviceRoleKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(<String, Object?>{
      'email': email,
      'password': password,
      'email_confirm': true,
    }),
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('admin user creation for $email failed: ${response.statusCode} ${response.body}');
  }
}

/// Extracted per the addendum: never a fixed sleep for the pull lag window
/// — poll [check] every 2 s until it is true, with a 60 s deadline that
/// throws naming the last call's result so a real failure does not read as
/// a silent hang.
Future<SupabaseSyncResult> _pollUntil(
  Future<SupabaseSyncResult> Function() run,
  bool Function() check, {
  Duration interval = const Duration(seconds: 2),
  Duration deadline = const Duration(seconds: 60),
}) async {
  final DateTime start = DateTime.now();
  SupabaseSyncResult last = await run();
  while (!check()) {
    if (DateTime.now().difference(start) >= deadline) {
      throw StateError('pollUntil timed out after $deadline; last result: ${_describe(last)}');
    }
    await Future<void>.delayed(interval);
    last = await run();
  }
  return last;
}

String _describe(SupabaseSyncResult r) =>
    'pushed=${r.pushed} pulled=${r.pulled} conflicts=${r.conflicts} '
    'tombstonesApplied=${r.tombstonesApplied} skipped=${r.skipped} '
    'failureReason=${r.failureReason}';

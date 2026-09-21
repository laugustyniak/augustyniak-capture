# Supabase Sync Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Versioned outbox/inbox metadata sync over Supabase for all seven user-owned tables, with tombstones, idempotent retry, and visible conflict resolution.

**Architecture:** A pure-Dart `SyncEngine` diffs local rows against a device-local `sync_rows` hash table, pushes dirty rows through a version-gated `sync_push` RPC, pulls by server-stamped `updated_at` with a 30 s lag window, and applies through the repositories (never raw SQL). `SupabaseSyncTransport` is the only file that imports `supabase_flutter`. The engine gets a third slot on the existing `CloudSyncCoordinator`.

**Tech Stack:** Dart/Flutter, `supabase_flutter` ^2.17 (PostgREST + RPC), `sqlite3` via `AppDatabase`, `crypto` (sha256), pgTAP via `supabase test db`.

**Spec:** `docs/superpowers/specs/2026-09-21-supabase-sync-protocol-design.md`

## Global Constraints

- Worktree: `.worktrees/feat-194-supabase-sync-protocol`, branch `feat/194-supabase-sync-protocol`, base `origin/main`. Every git command `git -C <worktree>`.
- Commits: Conventional Commits, footer `Refs #194`. No AI attribution.
- Never `INSERT OR REPLACE`; never raw SQL into `recordings`/`projects`/`clipboard_items` on the pull side.
- `sync_push` is `security invoker`. `owner_id` is never sent by the client.
- `authenticated` has no `delete` grant (schema from #190). Removal is `deleted_at`.
- `revisions` has no `update` grant and no `version`: push is `on conflict do nothing`.
- `transcript` never shrinks on pull.
- Sync never touches `status`, never marks a recording `failed`, never deletes except via the `deleteRecording` callback on a pulled tombstone.
- Every `fromJson`/decode degrades: a bad row is skipped and counted, never fatal.
- Tests are pure Dart with hand-written fakes (`docs/architecture/testing.md`). No widget binding unless the test is under `test/widget/`.
- Local Supabase stack: `supabase start` (already running), `supabase db reset`, `supabase test db`. **Never `supabase db push`.**
- English strings; every colour from `ConsolePalette`; no `const` on palette-painting widgets.

---

## File Structure

```
supabase/migrations/20260921090000_sync_push.sql          Task 1 — RPC
supabase/tests/sync_push_test.sql                          Task 1 — pgTAP
lib/core/database/app_database.dart                        Task 2 — sync_rows table
lib/features/sync/data/sync_rows_store.dart                Task 2 — SQLite access to sync_rows + cursors
lib/features/recordings/domain/recording_revision.dart     Task 3 — RevisionSource.sync
lib/features/sync/domain/sync_table.dart                   Task 4 — SyncTable enum, key columns
lib/features/sync/domain/sync_row_codec.dart               Task 4 — canonical JSON + hash
lib/features/sync/domain/sync_transport.dart               Task 5 — SyncTransport, DisabledSyncTransport, SyncPushResult
lib/features/sync/domain/sync_engine.dart                  Task 6+7 — diff, push, pull, apply
lib/features/sync/data/supabase_sync_transport.dart        Task 8 — PostgREST impl
lib/core/sync/cloud_sync_coordinator.dart                  Task 9 — third slot
lib/features/recordings/presentation/recordings_controller.dart  Task 9 — wiring
lib/features/settings/domain/app_settings.dart             Task 9 — syncDeviceId
lib/features/settings/presentation/sync_section.dart       Task 9 — copy
lib/app/app.dart                                           Task 9 — launch run
docs/architecture/sync.md, CLAUDE.md                       Task 9 — reference
test/sync/*_test.dart                                      Tasks 2–7
```

---

### Task 1: `sync_push` RPC and pgTAP

**Files:**
- Create: `supabase/migrations/20260921090000_sync_push.sql`
- Create: `supabase/tests/sync_push_test.sql`

**Interfaces:**
- Produces: `public.sync_push(table_name text, rows jsonb) returns jsonb` → `{"applied": int, "conflicts": [row jsonb, …]}`. Row keys are the table's column names. Client never sends `owner_id`, `updated_at`.

- [ ] **Step 1: Write the failing pgTAP test**

`supabase/tests/sync_push_test.sql`:

```sql
begin;
select plan(12);

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com');

create function pg_temp.sign_in(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true);
  select set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

-- 1. insert at version 1
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"One","version":1}]'))->>'applied',
  '1', 'insert at version 1 applies');
select is((select name from public.projects where id = 'p1'), 'One',
  'the row landed');

-- 2. update at version 2 over server 1
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"Two","version":2}]'))->>'applied',
  '1', 'update at version 2 over server 1 applies');
select is((select name from public.projects where id = 'p1'), 'Two',
  'the update landed');

-- 3. stale push: version 2 again over server 2 → conflict with server row
select is(
  jsonb_array_length((select public.sync_push('projects',
    '[{"id":"p1","name":"Stale","version":2}]'))->'conflicts'),
  1, 'a stale version is returned as a conflict');
select is((select name from public.projects where id = 'p1'), 'Two',
  'a stale push changes nothing');
select is(
  ((select public.sync_push('projects',
    '[{"id":"p1","name":"Stale","version":2}]'))->'conflicts'->0)->>'version',
  '2', 'the conflict carries the server row');

-- 4. tombstone through the version gate
select is(
  (select public.sync_push('projects',
    '[{"id":"p1","name":"Two","version":3,"deleted_at":"2026-09-21T00:00:00Z"}]'))->>'applied',
  '1', 'tombstone applies at the next version');
select ok((select deleted_at is not null from public.projects where id = 'p1'),
  'deleted_at is set');

-- 5. revisions: natural key, no-op on repeat, never a conflict
insert into public.recordings (id, file_path, duration_ms, type, status, created_at)
values ('r1', 'r1.m4a', 1, 'audioRecording', 'saved', now());
select is(
  (select public.sync_push('revisions',
    '[{"recording_id":"r1","at":"2026-01-01T00:00:00Z","field":"title","from_value":"a","to_value":"b","source":"user"},
      {"recording_id":"r1","at":"2026-01-01T00:00:00Z","field":"title","from_value":"a","to_value":"b","source":"user"}]'))->>'applied',
  '1', 'a repeated revision is a no-op, not a conflict');

-- 6. B pushing A's id creates B's own row
select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"Mine","version":1}]'))->>'applied',
  '1', 'B inserts its own p1');
select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');
select is((select name from public.projects where id = 'p1'), 'Two',
  'A''s p1 is untouched by B''s push');

-- 7. unknown table raises
select throws_ok($$ select public.sync_push('auth_users', '[]') $$,
  '22023', null, 'an unknown table name is rejected');

select * from finish();
rollback;
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd <worktree> && supabase db reset && supabase test db`
Expected: FAIL — `function public.sync_push(unknown, unknown) does not exist`.

- [ ] **Step 3: Write the migration**

`supabase/migrations/20260921090000_sync_push.sql`:

```sql
-- Version-gated push for the user-owned metadata tables (#194).
--
-- `security invoker`: every policy from the schema migration still applies,
-- so this function can only ever touch the caller's rows. `owner_id` is never
-- read from the payload — the column default fills it on insert and the
-- ownership trigger refuses a change on update. `updated_at` is likewise
-- ignored; the server stamps it.
--
-- For the six versioned tables a row is applied when it inserts, or when it
-- updates a row whose version is exactly one behind. A row that matches
-- nothing is returned in `conflicts` with the server's current row, so the
-- caller can resolve without a second round trip. `revisions` has no version
-- and no update grant: it inserts on its natural key and a repeat is a no-op.

create or replace function public.sync_push(table_name text, rows jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  key_columns text[];
  data_columns text[];
  row jsonb;
  applied integer := 0;
  conflicts jsonb := '[]'::jsonb;
  touched integer;
  current_row jsonb;
begin
  key_columns := case table_name
    when 'projects' then array['id']
    when 'recordings' then array['id']
    when 'segments' then array['recording_id', 'index']
    when 'clipboard_items' then array['id']
    when 'revisions' then array['recording_id', 'at', 'field']
    when 'devices' then array['id']
    when 'sync_state' then array['device_id', 'table_name']
    else null
  end;
  if key_columns is null then
    raise exception 'unknown table %', table_name
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a json array'
      using errcode = 'invalid_parameter_value';
  end if;

  for row in select value from jsonb_array_elements(rows)
  loop
    row := row - 'owner_id' - 'updated_at';
    select array_agg(k order by k) into data_columns
      from jsonb_object_keys(row) k;

    if table_name = 'revisions' then
      execute format(
        'insert into public.revisions (%s) select %s from jsonb_populate_record(null::public.revisions, $1) on conflict do nothing',
        (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c),
        (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c))
      using row;
      get diagnostics touched = row_count;
      applied := applied + touched;
      continue;
    end if;

    execute format(
      'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1) '
      'on conflict (owner_id, %3$s) do update set %4$s '
      'where public.%1$I.version = excluded.version - 1',
      table_name,
      (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c),
      (select string_agg(quote_ident(c), ', ') from unnest(key_columns) c),
      (select string_agg(format('%1$I = excluded.%1$I', c), ', ')
         from unnest(data_columns) c where c <> all (key_columns)))
    using row;
    get diagnostics touched = row_count;

    if touched = 1 then
      applied := applied + 1;
    else
      execute format(
        'select to_jsonb(t) from public.%1$I t where %2$s',
        table_name,
        (select string_agg(format('t.%1$I = ($1->>%2$L)::%3$s', c, c,
           format_type(a.atttypid, a.atttypmod)), ' and ')
           from unnest(key_columns) c
           join pg_attribute a on a.attname = c
            and a.attrelid = format('public.%I', table_name)::regclass))
      into current_row using row;
      conflicts := conflicts || coalesce(current_row, row);
    end if;
  end loop;

  return jsonb_build_object('applied', applied, 'conflicts', conflicts);
end;
$$;

revoke all on function public.sync_push(text, jsonb) from public, anon;
grant execute on function public.sync_push(text, jsonb) to authenticated;
```

Note on the `where` inside the `on conflict … do update`: when it is false the update touches zero rows and `row_count` is 0 — that is the gate. The conflict lookup then reads the server row through RLS, so B can never see A's row here either (`coalesce(current_row, row)` returns the pushed row when nothing is visible, which only happens when the conflict was a cross-owner key — impossible with owner-scoped keys, but the function must not fail).

- [ ] **Step 4: Run the suite**

Run: `cd <worktree> && supabase db reset && supabase test db`
Expected: `Result: PASS`, `Tests=12`. If the `jsonb_populate_record` cast of `at`/`created_at` fails on the `Z` suffix, Postgres accepts ISO-8601 with `Z` for `timestamptz` — check the error text before changing the payload.

- [ ] **Step 5: Prove the gate is real**

Comment out `where public.%1$I.version = excluded.version - 1` in the migration, `supabase db reset && supabase test db`, expect test 5 ("a stale version is returned as a conflict") to fail. Restore, reset, PASS.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add supabase
git -C <worktree> commit -m "feat(sync): add version-gated sync_push rpc

Refs #194"
```

---

### Task 2: `sync_rows` table and `SyncRowsStore`

**Files:**
- Modify: `lib/core/database/app_database.dart` (add table beside `settings`, ~line 125)
- Create: `lib/features/sync/data/sync_rows_store.dart`
- Test: `test/sync/sync_rows_store_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class SyncRowState { final int serverVersion; final String pushedHash; }
  class SyncRowsStore {
    SyncRowsStore(Database db);
    Map<String, SyncRowState> loadTable(String table);        // id → state
    void put(String table, String id, int serverVersion, String pushedHash);
    void remove(String table, String id);
    DateTime? cursor(String table);                          // settings key sync.cursor.<table>
    void setCursor(String table, DateTime value);
  }
  ```

- [ ] **Step 1: Write the failing test**

`test/sync/sync_rows_store_test.dart`:

```dart
import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/sync/data/sync_rows_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SyncRowsStore store;

  setUp(() async {
    db = sqlite3.openInMemory();
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: db);
    store = SyncRowsStore(db);
  });

  tearDown(() {
    db.dispose();
    AppDatabase.resetForTesting();
  });

  test('put then loadTable round-trips per table', () {
    store.put('recordings', 'a', 3, 'h1');
    store.put('projects', 'a', 1, 'h2');
    final Map<String, SyncRowState> rows = store.loadTable('recordings');
    expect(rows.keys, <String>['a']);
    expect(rows['a']!.serverVersion, 3);
    expect(rows['a']!.pushedHash, 'h1');
  });

  test('put overwrites, remove forgets', () {
    store.put('recordings', 'a', 1, 'h1');
    store.put('recordings', 'a', 2, 'h2');
    expect(store.loadTable('recordings')['a']!.serverVersion, 2);
    store.remove('recordings', 'a');
    expect(store.loadTable('recordings'), isEmpty);
  });

  test('cursor is absent until set and survives a round-trip in UTC', () {
    expect(store.cursor('recordings'), isNull);
    final DateTime at = DateTime.utc(2026, 9, 21, 10, 0, 0, 123);
    store.setCursor('recordings', at);
    expect(store.cursor('recordings'), at);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && flutter test test/sync/sync_rows_store_test.dart`
Expected: FAIL — `sync_rows_store.dart` not found.

- [ ] **Step 3: Add the table to `AppDatabase`**

In `lib/core/database/app_database.dart`, after the `settings` `CREATE TABLE`, add:

```dart
    // Device-local sync bookkeeping (#194): the server version last
    // acknowledged for a row and the hash of what was pushed. Not part of the
    // backup archive — it must not travel with a restore.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sync_rows (
        table_name TEXT NOT NULL,
        id TEXT NOT NULL,
        server_version INTEGER NOT NULL,
        pushed_hash TEXT NOT NULL,
        PRIMARY KEY (table_name, id)
      )
    ''');
```

- [ ] **Step 4: Write the store**

`lib/features/sync/data/sync_rows_store.dart`:

```dart
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// What the server last acknowledged for one local row.
class SyncRowState {
  const SyncRowState({required this.serverVersion, required this.pushedHash});

  final int serverVersion;
  final String pushedHash;
}

/// Device-local sync bookkeeping over the `sync_rows` table and the
/// `sync.cursor.<table>` keys of the `settings` table. Synchronous like the
/// rest of `AppDatabase`.
class SyncRowsStore {
  SyncRowsStore(this._db);

  final Database _db;

  Map<String, SyncRowState> loadTable(String table) {
    final ResultSet rows = _db.select(
      'SELECT id, server_version, pushed_hash FROM sync_rows WHERE table_name = ?',
      <Object>[table],
    );
    return <String, SyncRowState>{
      for (final Row row in rows)
        row['id'] as String: SyncRowState(
          serverVersion: row['server_version'] as int,
          pushedHash: row['pushed_hash'] as String,
        ),
    };
  }

  void put(String table, String id, int serverVersion, String pushedHash) {
    _db.execute(
      'INSERT INTO sync_rows (table_name, id, server_version, pushed_hash) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT (table_name, id) DO UPDATE SET '
      'server_version = excluded.server_version, '
      'pushed_hash = excluded.pushed_hash',
      <Object>[table, id, serverVersion, pushedHash],
    );
  }

  void remove(String table, String id) {
    _db.execute(
      'DELETE FROM sync_rows WHERE table_name = ? AND id = ?',
      <Object>[table, id],
    );
  }

  DateTime? cursor(String table) {
    final ResultSet rows = _db.select(
      'SELECT value_json FROM settings WHERE key = ?',
      <Object>['sync.cursor.$table'],
    );
    if (rows.isEmpty) return null;
    final Object? raw = jsonDecode(rows.single['value_json'] as String);
    return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
  }

  void setCursor(String table, DateTime value) {
    _db.execute(
      'INSERT INTO settings (key, value_json) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value_json = excluded.value_json',
      <Object>['sync.cursor.$table', jsonEncode(value.toUtc().toIso8601String())],
    );
  }
}
```

- [ ] **Step 5: Run the test**

Run: `cd <worktree> && flutter test test/sync/sync_rows_store_test.dart`
Expected: PASS (3 tests). Also `flutter test test/legacy_migration_test.dart test/sqlite_index_divergence_test.dart` still PASS — the new table must not disturb the existing schema tests.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add lib/core/database/app_database.dart lib/features/sync/data/sync_rows_store.dart test/sync/sync_rows_store_test.dart
git -C <worktree> commit -m "feat(sync): add device-local sync_rows bookkeeping

Refs #194"
```

---

### Task 3: `RevisionSource.sync`

**Files:**
- Modify: `lib/features/recordings/domain/recording_revision.dart:7-22`
- Test: `test/recording_revision_test.dart` (existing; extend)

**Interfaces:**
- Produces: `RevisionSource.sync` with `label` `'SYNC'`; `fromName('sync')` resolves it; unknown still degrades to `processor`.

- [ ] **Step 1: Write the failing test**

Append to the existing `group` in `test/recording_revision_test.dart`:

```dart
  test('sync source round-trips and labels as SYNC', () {
    final RecordingRevision revision = RecordingRevision(
      recordingId: 'r',
      at: DateTime.utc(2026, 9, 21),
      field: 'title',
      from: 'a',
      to: 'b',
      source: RevisionSource.sync,
    );
    final RecordingRevision back =
        RecordingRevision.fromJson(revision.toJson());
    expect(back.source, RevisionSource.sync);
    expect(RevisionSource.sync.label, 'SYNC');
    expect(RevisionSource.fromName('nonsense'), RevisionSource.processor);
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && flutter test test/recording_revision_test.dart`
Expected: FAIL — `sync` isn't defined for `RevisionSource`.

- [ ] **Step 3: Add the value**

In `recording_revision.dart`, after `processor`:

```dart
  /// Another device's edit that overwrote this one during a cloud sync — the
  /// server row was newer, and what it replaced is kept here so the loss is
  /// visible in HISTORY rather than silent.
  sync;
```

(turn `processor;` into `processor,`) and extend `label`:

```dart
    RevisionSource.sync => 'SYNC',
```

- [ ] **Step 4: Run the test**

Run: `cd <worktree> && flutter test test/recording_revision_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add lib/features/recordings/domain/recording_revision.dart test/recording_revision_test.dart
git -C <worktree> commit -m "feat(revisions): add the sync revision source

Refs #194"
```

---

### Task 4: `SyncTable` and `SyncRowCodec`

**Files:**
- Create: `lib/features/sync/domain/sync_table.dart`
- Create: `lib/features/sync/domain/sync_row_codec.dart`
- Test: `test/sync/sync_row_codec_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum SyncTable { projects, recordings, segments, clipboardItems, revisions, devices, syncState }
  extension on SyncTable { String get name /* server table name */; List<String> get keyColumns; }
  class SyncRowCodec {
    // local → server column map, no owner_id/updated_at
    static Map<String, Object?> recording(Recording r);
    static List<Map<String, Object?>> segments(Recording r);   // one per segment, recording_id set
    static Map<String, Object?> project(Project p);
    static Map<String, Object?> clipboardItem(ClipboardItem c);
    static Map<String, Object?> revision(RecordingRevision r);
    static Map<String, Object?> device({required String id, required String name, required String platform, String? appVersion});
    // server → local
    static Recording? recordingFromRow(Map<String, Object?> row, {Recording? local});
    static Project? projectFromRow(Map<String, Object?> row);
    static ClipboardItem? clipboardItemFromRow(Map<String, Object?> row);
    static RecordingRevision? revisionFromRow(Map<String, Object?> row);
    static String rowId(SyncTable table, Map<String, Object?> row);   // key columns joined with '/'
    static String hash(Map<String, Object?> row);                     // sha256 of canonical JSON, version/deleted_at excluded
  }
  ```

The canonical row for hashing excludes `version` and `deleted_at` (bookkeeping, not content) and sorts keys. `recording()` puts everything `toJson` carries that has no column — `thumbPath`, `routes`, `artifacts`, `segments` — into `payload` so a round trip through the server loses nothing; `recordingFromRow` rebuilds from columns and `payload`, preferring `local`'s `segments` list when the server payload has none.

- [ ] **Step 1: Write the failing tests**

`test/sync/sync_row_codec_test.dart`:

```dart
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording({String? title, String? transcript}) => Recording(
  id: 'rec-1',
  filePath: '/tmp/rec-1.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1200,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  title: title,
  transcript: transcript,
  category: CaptureCategory.idea,
  tags: const <String>['a', 'b'],
);

void main() {
  test('recording row uses server column names and only the file name', () {
    final Map<String, Object?> row = SyncRowCodec.recording(_recording(title: 'T'));
    expect(row['id'], 'rec-1');
    expect(row['file_path'], 'rec-1.m4a');
    expect(row['created_at'], '2026-09-21T08:00:00.000Z');
    expect(row['tags'], <String>['a', 'b']);
    expect(row['category'], 'idea');
    expect(row.containsKey('owner_id'), isFalse);
    expect(row.containsKey('updated_at'), isFalse);
  });

  test('hash ignores version and deleted_at and key order', () {
    final Map<String, Object?> a = <String, Object?>{'id': 'x', 'title': 't', 'version': 1};
    final Map<String, Object?> b = <String, Object?>{'title': 't', 'id': 'x', 'version': 9, 'deleted_at': null};
    expect(SyncRowCodec.hash(a), SyncRowCodec.hash(b));
    expect(SyncRowCodec.hash(a), isNot(SyncRowCodec.hash(<String, Object?>{'id': 'x', 'title': 'u'})));
  });

  test('recording round-trips through a server row', () {
    final Recording original = _recording(title: 'T', transcript: 'hello');
    final Map<String, Object?> row = SyncRowCodec.recording(original)
      ..['version'] = 4
      ..['updated_at'] = '2026-09-21T09:00:00Z'
      ..['deleted_at'] = null;
    final Recording? back = SyncRowCodec.recordingFromRow(row, local: original);
    expect(back, isNotNull);
    expect(back!.toJson()..remove('filePath'), original.toJson()..remove('filePath'));
    expect(back.filePath, original.filePath, reason: 'local path is kept when present');
  });

  test('a recording row missing its id decodes to null, not a throw', () {
    expect(SyncRowCodec.recordingFromRow(<String, Object?>{'title': 'x'}), isNull);
  });

  test('composite row ids join key columns with /', () {
    final RecordingRevision revision = RecordingRevision(
      recordingId: 'rec-1', at: DateTime.utc(2026, 1, 1), field: 'title',
      from: 'a', to: 'b', source: RevisionSource.user,
    );
    final Map<String, Object?> row = SyncRowCodec.revision(revision);
    expect(SyncRowCodec.rowId(SyncTable.revisions, row),
        'rec-1/2026-01-01T00:00:00.000Z/title');
    expect(row['from_value'], 'a');
    expect(row['to_value'], 'b');
  });

  test('table names and keys match the schema', () {
    expect(SyncTable.clipboardItems.name, 'clipboard_items');
    expect(SyncTable.segments.keyColumns, <String>['recording_id', 'index']);
    expect(SyncTable.syncState.keyColumns, <String>['device_id', 'table_name']);
  });
}
```

Add the same shape of round-trip test for `project`/`projectFromRow` and `clipboardItem`/`clipboardItemFromRow` (build one instance, encode, add `version`/`updated_at`, decode, compare `toJson()`), and one for `segments()` producing `recording_id`/`index` per segment.

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && flutter test test/sync/sync_row_codec_test.dart`
Expected: FAIL — files missing.

- [ ] **Step 3: Write `sync_table.dart`**

```dart
/// The seven server tables and the columns that key each one — the same
/// list `sync_push` validates against.
enum SyncTable {
  projects('projects', <String>['id']),
  recordings('recordings', <String>['id']),
  segments('segments', <String>['recording_id', 'index']),
  clipboardItems('clipboard_items', <String>['id']),
  revisions('revisions', <String>['recording_id', 'at', 'field']),
  devices('devices', <String>['id']),
  syncState('sync_state', <String>['device_id', 'table_name']);

  const SyncTable(this.name, this.keyColumns);

  final String name;
  final List<String> keyColumns;

  /// Versioned tables take the conflict gate; revisions are append-only.
  bool get versioned => this != SyncTable.revisions;
}
```

Note: `name` shadows the enum's built-in `name` getter deliberately so `SyncTable.clipboardItems.name` is the server spelling; declare it as a field, which is allowed in an enhanced enum.

- [ ] **Step 4: Write `sync_row_codec.dart`**

```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/capture_segment.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';
import 'sync_table.dart';

/// Canonical server-row shape for each synced type, and the hash the engine
/// compares against `sync_rows.pushed_hash`.
///
/// A row never carries `owner_id` or `updated_at`: the server owns both. The
/// hash excludes `version` and `deleted_at` — bookkeeping, not content — so a
/// row's identity is what the user would recognise as the same capture.
class SyncRowCodec {
  SyncRowCodec._();

  static String _utc(DateTime at) => at.toUtc().toIso8601String();
  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  static String hash(Map<String, Object?> row) {
    final Map<String, Object?> canonical = Map<String, Object?>.fromEntries(
      row.entries
          .where((MapEntry<String, Object?> e) =>
              e.key != 'version' && e.key != 'deleted_at' &&
              e.key != 'owner_id' && e.key != 'updated_at')
          .toList()
        ..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
            a.key.compareTo(b.key)),
    );
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static String rowId(SyncTable table, Map<String, Object?> row) =>
      table.keyColumns.map((String c) => '${row[c]}').join('/');

  // ---- recordings ---------------------------------------------------------

  static Map<String, Object?> recording(Recording r) {
    final Map<String, dynamic> json = r.toJson();
    // Everything with no column of its own rides in `payload`.
    final Map<String, Object?> payload = <String, Object?>{
      'thumbPath': json['thumbPath'],
      'routes': json['routes'],
      'artifacts': json['artifacts'],
      if (json.containsKey('segments')) 'segments': json['segments'],
    };
    return <String, Object?>{
      'id': r.id,
      'file_path': p.basename(r.filePath),
      'duration_ms': r.durationMs,
      'size_bytes': r.sizeBytes,
      'content_hash': r.contentHash,
      'type': r.type.name,
      'status': r.status.name,
      'source_mime_type': r.sourceMimeType,
      'transcript': r.transcript,
      'category': r.category?.name,
      'title': r.title,
      'summary': r.summary,
      'tags': r.tags,
      'created_at': _utc(r.createdAt),
      'is_processed_by_user': r.isProcessedByUser,
      'processed_at': r.processedAt == null ? null : _utc(r.processedAt!),
      'project_id': r.projectId,
      'failure_reason': r.error,
      'payload': payload,
    };
  }

  static Recording? recordingFromRow(Map<String, Object?> row, {Recording? local}) {
    final Object? id = row['id'];
    final DateTime? createdAt = _date(row['created_at']);
    if (id is! String || createdAt == null) return null;
    final Object? payloadRaw = row['payload'];
    final Map<String, dynamic> payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};
    final String fileName = row['file_path'] is String ? row['file_path'] as String : '';
    final Map<String, dynamic> json = <String, dynamic>{
      'id': id,
      // Keep the local absolute path; a fresh install gets the bare name and
      // slice 4 resolves it against the recordings directory.
      'filePath': local?.filePath ?? fileName,
      'createdAt': createdAt.toIso8601String(),
      'durationMs': row['duration_ms'] is int ? row['duration_ms'] : 0,
      'sizeBytes': row['size_bytes'] is int ? row['size_bytes'] : 0,
      'contentHash': row['content_hash'],
      'status': row['status'],
      'type': row['type'],
      'sourceMimeType': row['source_mime_type'],
      'transcript': row['transcript'],
      'thumbPath': payload['thumbPath'],
      'title': row['title'],
      'category': row['category'],
      'summary': row['summary'],
      'tags': row['tags'] is List ? row['tags'] : <String>[],
      'projectId': row['project_id'],
      'error': row['failure_reason'],
      'isProcessedByUser': row['is_processed_by_user'] == true,
      'processedAt': row['processed_at'],
      'routes': payload['routes'] ?? <Object?>[],
      'artifacts': payload['artifacts'] ?? <Object?>[],
      if (payload.containsKey('segments'))
        'segments': payload['segments']
      else if (local != null && local.toJson().containsKey('segments'))
        'segments': local.toJson()['segments'],
    };
    try {
      return Recording.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, Object?>> segments(Recording r) {
    final Object? raw = r.toJson()['segments'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map)
          <String, Object?>{
            'recording_id': r.id,
            'index': item['index'],
            'file_path': p.basename(item['filePath'] as String? ?? ''),
            'type': item['type'],
            'source_mime_type': item['sourceMimeType'],
            'created_at': item['createdAt'],
            'duration_ms': item['durationMs'],
            'size_bytes': item['sizeBytes'],
            'content_hash': item['contentHash'],
            'text': item['text'],
            'error': item['error'],
          },
    ];
  }

  // ---- projects -----------------------------------------------------------

  static Map<String, Object?> project(Project pr) => <String, Object?>{
    'id': pr.id,
    'name': pr.name,
    'repository_path': pr.repoPath,
    'payload': pr.toJson()..remove('id')..remove('name')..remove('repoPath'),
  };

  static Project? projectFromRow(Map<String, Object?> row) {
    if (row['id'] is! String) return null;
    final Object? payloadRaw = row['payload'];
    final Map<String, dynamic> json = <String, dynamic>{
      if (payloadRaw is Map) ...Map<String, dynamic>.from(payloadRaw),
      'id': row['id'],
      'name': row['name'],
      'repoPath': row['repository_path'] ?? '',
    };
    try {
      return Project.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---- clipboard ----------------------------------------------------------

  static Map<String, Object?> clipboardItem(ClipboardItem c) => <String, Object?>{
    'id': c.id,
    'type': c.type.name,
    'text': c.text,
    'image_path': c.imagePath == null ? null : p.basename(c.imagePath!),
    'copied_at': _utc(c.copiedAt),
    'preview': c.preview,
    'collections': c.collections.toList()..sort(),
  };

  static ClipboardItem? clipboardItemFromRow(Map<String, Object?> row) {
    if (row['id'] is! String || _date(row['copied_at']) == null) return null;
    try {
      return ClipboardItem.fromJson(<String, dynamic>{
        'id': row['id'],
        'type': row['type'],
        'copiedAt': _date(row['copied_at'])!.toIso8601String(),
        if (row['text'] != null) 'text': row['text'],
        if (row['image_path'] != null) 'imagePath': row['image_path'],
        if (row['preview'] != null) 'preview': row['preview'],
        if (row['collections'] is List) 'collections': row['collections'],
      });
    } catch (_) {
      return null;
    }
  }

  // ---- revisions ----------------------------------------------------------

  static Map<String, Object?> revision(RecordingRevision r) => <String, Object?>{
    'recording_id': r.recordingId,
    'at': _utc(r.at),
    'field': r.field,
    'from_value': r.from,
    'to_value': r.to,
    'source': r.source.name,
  };

  static RecordingRevision? revisionFromRow(Map<String, Object?> row) {
    final DateTime? at = _date(row['at']);
    if (row['recording_id'] is! String || row['field'] is! String || at == null) {
      return null;
    }
    return RecordingRevision(
      recordingId: row['recording_id'] as String,
      at: at,
      field: row['field'] as String,
      from: row['from_value'] as String?,
      to: row['to_value'] as String?,
      source: RevisionSource.fromName(row['source'] as String?),
    );
  }

  // ---- devices ------------------------------------------------------------

  static Map<String, Object?> device({
    required String id,
    required String name,
    required String platform,
    String? appVersion,
  }) => <String, Object?>{
    'id': id,
    'name': name,
    'platform': platform,
    'app_version': appVersion,
  };
}
```

Adjust the exact `Project.toJson()`/`fromJson` and `ClipboardItem.fromJson` field names to what the files actually use (`repoPath` and `copiedAt` are confirmed; check `ClipboardItem.fromJson` accepts a `collections` list). The `_recording` fixture in the test uses `RecordingStatus.completed` and `CaptureCategory.idea` — confirm both exist in `capture_type.dart` / `capture_category.dart` and substitute the real names if not.

- [ ] **Step 5: Run the tests**

Run: `cd <worktree> && flutter test test/sync/sync_row_codec_test.dart && flutter analyze`
Expected: PASS, `No issues found!`.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add lib/features/sync/domain test/sync/sync_row_codec_test.dart
git -C <worktree> commit -m "feat(sync): add the server row codec and table map

Refs #194"
```

---

### Task 5: `SyncTransport` seam

**Files:**
- Create: `lib/features/sync/domain/sync_transport.dart`
- Create: `test/sync/fake_sync_transport.dart` (test helper, no `_test` suffix)
- Test: `test/sync/sync_transport_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class SyncPushResult { final int applied; final List<Map<String, Object?>> conflicts; }
  class SyncPage { final List<Map<String, Object?>> rows; final bool hasMore; }
  abstract interface class SyncTransport {
    Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows);
    Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit});
    Future<DateTime> serverNow();
  }
  class DisabledSyncTransport implements SyncTransport { /* throws StateError('Cloud sync is not configured') at use */ }
  ```
- `FakeSyncTransport` (test helper): in-memory per-table map keyed by `rowId`, implements the same version gate as the RPC, stamps `updated_at` from an injectable `clock`, records every call.

- [ ] **Step 1: Write the failing test** — `test/sync/sync_transport_test.dart`:

```dart
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
    expect((await fake.pull(SyncTable.projects, since: null, offset: 0, limit: 10)).rows, isEmpty);
    fake.clock = () => DateTime.utc(2026, 9, 21, 12, 1, 0);
    expect((await fake.pull(SyncTable.projects, since: null, offset: 0, limit: 10)).rows, hasLength(1));
  });
}
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL, files missing.

- [ ] **Step 3: Write `sync_transport.dart`**

```dart
import 'sync_table.dart';

class SyncPushResult {
  const SyncPushResult({required this.applied, required this.conflicts});
  final int applied;
  final List<Map<String, Object?>> conflicts;
}

class SyncPage {
  const SyncPage({required this.rows, required this.hasMore});
  final List<Map<String, Object?>> rows;
  final bool hasMore;
}

/// The wire. One implementation talks PostgREST; tests hand the engine an
/// in-memory fake that enforces the same version gate.
abstract interface class SyncTransport {
  /// `sync_push` for one table. Rows carry `version` (versioned tables) and
  /// never `owner_id`/`updated_at`.
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows);

  /// Rows with `updated_at > since - 30 s` and `updated_at <= now() - 30 s`,
  /// ordered `(updated_at, id)`, one page at a time.
  Future<SyncPage> pull(
    SyncTable table, {
    required DateTime? since,
    required int offset,
    required int limit,
  });

  Future<DateTime> serverNow();
}

/// The seam's default: wiring never fails, use does.
class DisabledSyncTransport implements SyncTransport {
  const DisabledSyncTransport();

  Never _unavailable() => throw StateError('Cloud sync is not configured');

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async =>
      _unavailable();

  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit}) async =>
      _unavailable();

  @override
  Future<DateTime> serverNow() async => _unavailable();
}

const Duration syncLagWindow = Duration(seconds: 30);
```

- [ ] **Step 4: Write `test/sync/fake_sync_transport.dart`**

```dart
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';

/// In-memory server with the same version gate as `sync_push` and the same
/// pull window. `clock` stamps `updated_at`.
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport({DateTime Function()? clock})
      : clock = clock ?? (() => DateTime.now().toUtc());

  DateTime Function() clock;
  final Map<SyncTable, Map<String, Map<String, Object?>>> tables =
      <SyncTable, Map<String, Map<String, Object?>>>{};
  final List<(SyncTable, List<Map<String, Object?>>)> pushes = [];
  Object? failWith;

  Map<String, Map<String, Object?>> _table(SyncTable t) =>
      tables.putIfAbsent(t, () => <String, Map<String, Object?>>{});

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async {
    if (failWith != null) throw failWith!;
    pushes.add((table, rows));
    int applied = 0;
    final List<Map<String, Object?>> conflicts = [];
    for (final Map<String, Object?> row in rows) {
      final String id = SyncRowCodec.rowId(table, row);
      final Map<String, Object?>? current = _table(table)[id];
      if (!table.versioned) {
        if (current == null) {
          _table(table)[id] = {...row, 'updated_at': clock().toIso8601String()};
          applied++;
        }
        continue;
      }
      final int incoming = row['version'] as int;
      final bool ok = current == null ? incoming == 1 : current['version'] == incoming - 1;
      if (ok) {
        _table(table)[id] = {...row, 'updated_at': clock().toIso8601String()};
        applied++;
      } else {
        conflicts.add(Map<String, Object?>.from(current ?? row));
      }
    }
    return SyncPushResult(applied: applied, conflicts: conflicts);
  }

  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit}) async {
    if (failWith != null) throw failWith!;
    final DateTime upper = clock().subtract(syncLagWindow);
    final DateTime? lower = since?.subtract(syncLagWindow);
    final List<Map<String, Object?>> all = _table(table).values.where((row) {
      final DateTime at = DateTime.parse(row['updated_at'] as String);
      return !at.isAfter(upper) && (lower == null || at.isAfter(lower));
    }).toList()
      ..sort((a, b) {
        final int c = (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return c != 0 ? c : SyncRowCodec.rowId(table, a).compareTo(SyncRowCodec.rowId(table, b));
      });
    final List<Map<String, Object?>> page = all.skip(offset).take(limit).map((r) => Map<String, Object?>.from(r)).toList();
    return SyncPage(rows: page, hasMore: offset + limit < all.length);
  }

  @override
  Future<DateTime> serverNow() async => clock();
}
```

- [ ] **Step 5: Run** — `flutter test test/sync/sync_transport_test.dart` → PASS.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add lib/features/sync/domain/sync_transport.dart test/sync/fake_sync_transport.dart test/sync/sync_transport_test.dart
git -C <worktree> commit -m "feat(sync): add the sync transport seam and in-memory fake

Refs #194"
```

---

### Task 6: `SyncEngine` — push side

**Files:**
- Create: `lib/features/sync/domain/sync_engine.dart`
- Create: `lib/features/sync/domain/sync_snapshot.dart` (the local rows the engine reads, and the writes it hands back)
- Test: `test/sync/sync_engine_push_test.dart`

**Interfaces:**
- Consumes: `SyncTransport`, `SyncRowCodec`, `SyncRowsStore`-shaped store.
- Produces:
  ```dart
  /// Storage the engine talks to — implemented by SyncRowsStore in production and by a map in tests.
  abstract interface class SyncBookkeeping {
    Map<String, SyncRowState> loadTable(String table);
    void put(String table, String id, int serverVersion, String pushedHash);
    void remove(String table, String id);
    DateTime? cursor(String table);
    void setCursor(String table, DateTime value);
  }
  class SyncSnapshot {  // what the device holds right now
    final List<Recording> recordings; final List<Project> projects;
    final List<ClipboardItem> clipboardItems; final List<RecordingRevision> revisions;
    final Map<String, Object?> device;
  }
  class SupabaseSyncResult { final int pushed, pulled, conflicts, tombstonesApplied, skipped; final String? failureReason; bool get success; }
  class SyncEngine {
    SyncEngine({required SyncTransport transport, required SyncBookkeeping bookkeeping, required SyncApplier applier, DateTime Function()? clock});
    Future<SupabaseSyncResult> run(SyncSnapshot snapshot);
  }
  ```
  `SyncApplier` is defined in Task 7; for this task declare it with the methods the pull needs and give the test a no-op implementation.

Move `SyncRowState` from `sync_rows_store.dart` into `sync_snapshot.dart` (domain) and have the store import it, so the domain never imports `sqlite3`. Make `SyncRowsStore implements SyncBookkeeping`.

- [ ] **Step 1: Write the failing tests** — `test/sync/sync_engine_push_test.dart`:

```dart
import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_transport.dart';
import 'sync_fixtures.dart';   // _recording(), MemoryBookkeeping, NoopApplier — write these in this task

void main() {
  late FakeSyncTransport transport;
  late MemoryBookkeeping bookkeeping;
  late SyncEngine engine;

  setUp(() {
    transport = FakeSyncTransport(clock: () => DateTime.utc(2026, 9, 21, 12));
    bookkeeping = MemoryBookkeeping();
    engine = SyncEngine(transport: transport, bookkeeping: bookkeeping, applier: NoopApplier());
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
    expect(transport.pushes.where((p) => p.$1 == SyncTable.recordings && p.$2.isNotEmpty), isEmpty);
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
    final r = await engine.run(SyncSnapshot(recordings: [rec], revisions: [revision(recordingId: 'a')]));
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

  test('pushes are batched at 200 rows', () async {
    final rows = [for (int i = 0; i < 450; i++) clipboardItem(id: 'c$i')];
    await engine.run(SyncSnapshot(clipboardItems: rows));
    final batches = transport.pushes.where((p) => p.$1 == SyncTable.clipboardItems).toList();
    expect(batches.map((b) => b.$2.length), [200, 200, 50]);
  });
}
```

`test/sync/sync_fixtures.dart` holds `recording()`, `recordingWithSegments()`, `revision()`, `clipboardItem()`, `project()` builders, `MemoryBookkeeping` (a `Map<String, Map<String, SyncRowState>>` + cursors map implementing `SyncBookkeeping`) and `NoopApplier`.

- [ ] **Step 2: Run to verify failure** — FAIL, `sync_engine.dart` missing.

- [ ] **Step 3: Write `sync_snapshot.dart`**

```dart
import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';

class SyncRowState {
  const SyncRowState({required this.serverVersion, required this.pushedHash});
  final int serverVersion;
  final String pushedHash;
}

abstract interface class SyncBookkeeping {
  Map<String, SyncRowState> loadTable(String table);
  void put(String table, String id, int serverVersion, String pushedHash);
  void remove(String table, String id);
  DateTime? cursor(String table);
  void setCursor(String table, DateTime value);
}

/// Everything the device holds that syncs, read once at the start of a run.
class SyncSnapshot {
  const SyncSnapshot({
    this.recordings = const <Recording>[],
    this.projects = const <Project>[],
    this.clipboardItems = const <ClipboardItem>[],
    this.revisions = const <RecordingRevision>[],
    this.device = const <String, Object?>{},
  });
  final List<Recording> recordings;
  final List<Project> projects;
  final List<ClipboardItem> clipboardItems;
  final List<RecordingRevision> revisions;
  final Map<String, Object?> device;
}

class SupabaseSyncResult {
  const SupabaseSyncResult({
    this.pushed = 0, this.pulled = 0, this.conflicts = 0,
    this.tombstonesApplied = 0, this.skipped = 0, this.failureReason,
  });
  final int pushed, pulled, conflicts, tombstonesApplied, skipped;
  final String? failureReason;
  bool get success => failureReason == null;
}
```

- [ ] **Step 4: Write the push half of `sync_engine.dart`**

```dart
import 'sync_row_codec.dart';
import 'sync_snapshot.dart';
import 'sync_table.dart';
import 'sync_transport.dart';

/// What the pull side does to the device — see Task 7. Declared here so the
/// engine has one constructor from the start.
abstract interface class SyncApplier {
  Future<void> upsertRecordings(List<Recording> rows);
  Future<void> upsertProjects(List<Project> rows);
  Future<void> upsertClipboardItems(List<ClipboardItem> rows);
  Future<void> appendRevisions(List<RecordingRevision> rows);
  Future<void> deleteRecording(String id);
}

const int syncBatchSize = 200;

class SyncEngine {
  SyncEngine({
    required SyncTransport transport,
    required SyncBookkeeping bookkeeping,
    required SyncApplier applier,
    DateTime Function()? clock,
  })  : _transport = transport, _bookkeeping = bookkeeping, _applier = applier,
        _clock = clock ?? (() => DateTime.now().toUtc());

  final SyncTransport _transport;
  final SyncBookkeeping _bookkeeping;
  final SyncApplier _applier;
  final DateTime Function() _clock;

  Future<SupabaseSyncResult> run(SyncSnapshot snapshot) async {
    int pushed = 0, conflicts = 0;
    try {
      for (final _Outbox outbox in _outboxes(snapshot)) {
        final _PushOutcome outcome = await _pushTable(outbox);
        pushed += outcome.applied;
        conflicts += outcome.conflicts;
      }
    } catch (error) {
      return SupabaseSyncResult(pushed: pushed, conflicts: conflicts, failureReason: '$error');
    }
    return SupabaseSyncResult(pushed: pushed, conflicts: conflicts);
    // Task 7 adds the pull between the push and the return.
  }

  /// One table's local rows in server shape, keyed by row id.
  Iterable<_Outbox> _outboxes(SyncSnapshot s) sync* {
    yield _Outbox(SyncTable.projects, {for (final p in s.projects) p.id: SyncRowCodec.project(p)});
    yield _Outbox(SyncTable.recordings, {for (final r in s.recordings) r.id: SyncRowCodec.recording(r)});
    yield _Outbox(SyncTable.segments, {
      for (final r in s.recordings)
        for (final seg in SyncRowCodec.segments(r)) SyncRowCodec.rowId(SyncTable.segments, seg): seg,
    });
    yield _Outbox(SyncTable.clipboardItems, {for (final c in s.clipboardItems) c.id: SyncRowCodec.clipboardItem(c)});
    yield _Outbox(SyncTable.revisions, {
      for (final rev in s.revisions)
        SyncRowCodec.rowId(SyncTable.revisions, SyncRowCodec.revision(rev)): SyncRowCodec.revision(rev),
    });
    if (s.device.isNotEmpty) yield _Outbox(SyncTable.devices, {s.device['id'] as String: s.device});
  }

  Future<_PushOutcome> _pushTable(_Outbox outbox) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable(outbox.table.name);
    final List<(String, Map<String, Object?>, String)> dirty = []; // id, row, hash

    for (final MapEntry<String, Map<String, Object?>> e in outbox.rows.entries) {
      final String hash = SyncRowCodec.hash(e.value);
      final SyncRowState? state = known[e.key];
      if (state != null && state.pushedHash == hash) continue;
      final Map<String, Object?> row = Map<String, Object?>.from(e.value);
      if (outbox.table.versioned) row['version'] = (state?.serverVersion ?? 0) + 1;
      dirty.add((e.key, row, hash));
    }
    // Known to the server, gone from the device: tombstone at the next version.
    if (outbox.table.versioned) {
      for (final MapEntry<String, SyncRowState> e in known.entries) {
        if (outbox.rows.containsKey(e.key)) continue;
        dirty.add((e.key, _tombstone(outbox.table, e.key, e.value.serverVersion + 1), ''));
      }
    }

    int applied = 0, conflicts = 0;
    for (int i = 0; i < dirty.length; i += syncBatchSize) {
      final List<(String, Map<String, Object?>, String)> batch = dirty.sublist(i, (i + syncBatchSize).clamp(0, dirty.length));
      final SyncPushResult result = await _transport.push(outbox.table, [for (final d in batch) d.$2]);
      final Set<String> conflicted = {for (final c in result.conflicts) SyncRowCodec.rowId(outbox.table, c)};
      for (final (String id, Map<String, Object?> row, String hash) in batch) {
        if (conflicted.contains(id)) { conflicts++; continue; }
        applied++;
        if (row['deleted_at'] != null) {
          _bookkeeping.remove(outbox.table.name, id);
        } else {
          _bookkeeping.put(outbox.table.name, id, outbox.table.versioned ? row['version'] as int : 0, hash);
        }
      }
      // Task 7 applies `result.conflicts` through the same path as pulled rows.
    }
    return _PushOutcome(applied, conflicts);
  }

  Map<String, Object?> _tombstone(SyncTable table, String id, int version) {
    final List<String> parts = id.split('/');
    return <String, Object?>{
      for (int i = 0; i < table.keyColumns.length; i++)
        table.keyColumns[i]: table.keyColumns[i] == 'index' ? int.parse(parts[i]) : parts[i],
      'version': version,
      'deleted_at': _clock().toIso8601String(),
    };
  }
}

class _Outbox {
  const _Outbox(this.table, this.rows);
  final SyncTable table;
  final Map<String, Map<String, Object?>> rows;
}

class _PushOutcome {
  const _PushOutcome(this.applied, this.conflicts);
  final int applied, conflicts;
}

/// Mutable tally for the pull side (Task 7 fills it).
class _PullOutcome {
  int pulled = 0, conflicts = 0, tombstones = 0, skipped = 0;
  final List<Recording> redirtied = <Recording>[];
}
```

A tombstone row carries only key columns, `version`, `deleted_at` — `sync_push` updates just those (the `set` list is built from the payload's keys), which is what the schema wants: a tombstone is a flag, not a rewrite. For the `insert` half `jsonb_populate_record` needs `not null` columns present; a tombstone for a row the server never saw cannot happen (it was in `sync_rows`, so it was acknowledged), but `sync_push` must not crash if it does — the insert will raise on a null `not null` column and the engine reports the failure. Acceptable and noted.

- [ ] **Step 5: Run** — `flutter test test/sync/sync_engine_push_test.dart` → PASS. `flutter analyze` clean.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add lib/features/sync lib/features/sync/data/sync_rows_store.dart test/sync
git -C <worktree> commit -m "feat(sync): add the sync engine push side

Refs #194"
```

---

### Task 7: `SyncEngine` — pull and apply

**Files:**
- Modify: `lib/features/sync/domain/sync_engine.dart`
- Test: `test/sync/sync_engine_pull_test.dart`

**Interfaces:**
- Consumes: `SyncApplier` (Task 6), `SyncTransport.pull`, `SyncBookkeeping.cursor/setCursor`.
- Produces: `run()` now pushes, pulls every table, applies, re-pushes rows the transcript rule re-dirtied. Test helper `RecordingApplier` in `sync_fixtures.dart` records calls and holds an in-memory recordings map.

- [ ] **Step 1: Write the failing tests** — `test/sync/sync_engine_pull_test.dart`:

```dart
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
    engine = SyncEngine(transport: transport, bookkeeping: bookkeeping, applier: applier, clock: () => t0);
  });

  Future<void> seedServer(Recording r, {int version = 1}) =>
      transport.push(SyncTable.recordings, [{...SyncRowCodec.recording(r), 'version': version}]);

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
    await transport.push(SyncTable.recordings, [{...SyncRowCodec.recording(recording(id: 'a', title: 'v2')), 'version': 2}]);
    advance(const Duration(minutes: 1));
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'v1')]));
    expect(applier.recordings['a']!.title, 'v2');
    expect(applier.revisions, isEmpty, reason: 'nothing local was overwritten');
  });

  test('server wins a conflict and every overwritten field becomes a sync revision', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'base', summary: 'base')]));
    await transport.push(SyncTable.recordings, [{...SyncRowCodec.recording(recording(id: 'a', title: 'theirs', summary: 'base')), 'version': 2}]);
    advance(const Duration(minutes: 1));
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'mine', summary: 'mine')]));
    expect(r.conflicts, 1);
    expect(applier.recordings['a']!.title, 'theirs');
    expect(applier.recordings['a']!.summary, 'base');
    expect(applier.revisions.map((x) => (x.field, x.from, x.source)),
        containsAll([('title', 'mine', RevisionSource.sync), ('summary', 'mine', RevisionSource.sync)]));
  });

  test('a pulled tombstone deletes through the callback; a dirty local writes revisions first', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'base')]));
    await transport.push(SyncTable.recordings, [{'id': 'a', 'version': 2, 'deleted_at': t0.toIso8601String()}]);
    advance(const Duration(minutes: 1));
    final r = await engine.run(SyncSnapshot(recordings: [recording(id: 'a', title: 'mine')]));
    expect(r.tombstonesApplied, 1);
    expect(applier.deleted, ['a']);
    expect(applier.revisions.single.field, 'title');
    expect(bookkeeping.loadTable('recordings').containsKey('a'), isFalse);
  });

  test('transcript never shrinks: local kept, row re-pushed', () async {
    await engine.run(SyncSnapshot(recordings: [recording(id: 'a', transcript: 'one two')]));
    await transport.push(SyncTable.recordings, [{...SyncRowCodec.recording(recording(id: 'a', transcript: 'one')), 'version': 2}]);
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
    advance(const Duration(seconds: 50));   // cursor - 30 s still covers the row
    await engine.run(SyncSnapshot(recordings: [applier.recordings['a']!]));
    expect(applier.upserts, isEmpty, reason: 'same row, same version, nothing to apply');
  });

  test('a row that fails to decode is skipped and counted', () async {
    transport.tables.putIfAbsent(SyncTable.recordings, () => {})['bad'] = {'id': 'bad', 'updated_at': t0.toIso8601String(), 'version': 1};
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
    await transport.push(SyncTable.projects, [{...SyncRowCodec.project(project(id: 'p')), 'version': 1}]);
    await transport.push(SyncTable.clipboardItems, [{...SyncRowCodec.clipboardItem(clipboardItem(id: 'c')), 'version': 1}]);
    await transport.push(SyncTable.revisions, [SyncRowCodec.revision(revision(recordingId: 'a'))]);
    advance(const Duration(minutes: 1));
    await engine.run(const SyncSnapshot());
    expect(applier.projects.keys, ['p']);
    expect(applier.clipboardItems.keys, ['c']);
    expect(applier.revisions.single.recordingId, 'a');
  });
}
```

`RecordingApplier` (in `sync_fixtures.dart`): maps for recordings/projects/clipboardItems, a `revisions` list, a `deleted` list, an `upserts` log; `deleteRecording` removes from the map.

- [ ] **Step 2: Run to verify failure** — FAIL: pulled is 0, applier untouched.

- [ ] **Step 3: Add the pull to `run()` and the apply rules**

In `run()`, after the push loop and inside the same `try`:

```dart
      final _PullOutcome pull = await _pullAll(snapshot);
      pulled = pull.pulled; conflicts += pull.conflicts;
      tombstones = pull.tombstones; skipped = pull.skipped;
      if (pull.redirtied.isNotEmpty) {
        // The transcript rule kept a local value the server tried to shorten;
        // push it back so the server converges on the longer text.
        final _PushOutcome again = await _pushTable(_Outbox(SyncTable.recordings, {
          for (final r in pull.redirtied) r.id: SyncRowCodec.recording(r),
        }));
        pushed += again.applied; conflicts += again.conflicts;
      }
```

The pull per table:

```dart
  Future<_PullOutcome> _pullAll(SyncSnapshot s) async {
    final _PullOutcome total = _PullOutcome();
    final Map<String, Recording> localRecordings = {for (final r in s.recordings) r.id: r};
    for (final SyncTable table in [SyncTable.projects, SyncTable.recordings, SyncTable.clipboardItems, SyncTable.revisions]) {
      final DateTime? since = _bookkeeping.cursor(table.name);
      DateTime? newest = since;
      int offset = 0;
      final List<Map<String, Object?>> rows = [];
      while (true) {
        final SyncPage page = await _transport.pull(table, since: since, offset: offset, limit: 500);
        rows.addAll(page.rows);
        offset += page.rows.length;
        if (!page.hasMore) break;
      }
      for (final Map<String, Object?> row in rows) {
        final DateTime? at = DateTime.tryParse('${row['updated_at']}')?.toUtc();
        if (at != null && (newest == null || at.isAfter(newest))) newest = at;
      }
      switch (table) {
        case SyncTable.recordings: await _applyRecordings(rows, localRecordings, total);
        case SyncTable.projects: await _applySimple<Project>(table, rows, SyncRowCodec.projectFromRow, _applier.upsertProjects, total);
        case SyncTable.clipboardItems: await _applySimple<ClipboardItem>(table, rows, SyncRowCodec.clipboardItemFromRow, _applier.upsertClipboardItems, total);
        case SyncTable.revisions: await _applyRevisions(rows, total);
        default: break;
      }
      if (newest != null) _bookkeeping.setCursor(table.name, newest);
    }
    // Mirror the cursors to the server's sync_state row for this device so a
    // reinstall can see where its predecessor stopped. Versioned like any
    // other row; a conflict here is harmless and just counted.
    if (s.device['id'] is String) {
      final _PushOutcome mirrored = await _pushTable(_Outbox(SyncTable.syncState, {
        for (final SyncTable t in [SyncTable.projects, SyncTable.recordings, SyncTable.clipboardItems, SyncTable.revisions])
          '${s.device['id']}/${t.name}': <String, Object?>{
            'device_id': s.device['id'],
            'table_name': t.name,
            'pulled_through': _bookkeeping.cursor(t.name)?.toIso8601String(),
          },
      }));
      total.conflicts += mirrored.conflicts;
    }
    return total;
  }
```

Add one test: after a run with a device in the snapshot, `transport.tables[SyncTable.syncState]` holds four rows keyed `dev/<table>` with `pulled_through` equal to the cursor.

`_applyRecordings` implements the spec's table row by row:

```dart
  Future<void> _applyRecordings(List<Map<String, Object?>> rows, Map<String, Recording> local, _PullOutcome out) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable('recordings');
    final List<Recording> upserts = [];
    final List<RecordingRevision> revisions = [];
    for (final Map<String, Object?> row in rows) {
      final String? id = row['id'] as String?;
      if (id == null) { out.skipped++; continue; }
      final int serverVersion = row['version'] is int ? row['version'] as int : 0;
      final Recording? mine = local[id];
      final SyncRowState? state = known[id];
      final bool dirty = mine != null && (state == null || SyncRowCodec.hash(SyncRowCodec.recording(mine)) != state.pushedHash);

      if (row['deleted_at'] != null) {
        if (mine == null) { _bookkeeping.remove('recordings', id); continue; }
        if (dirty) revisions.addAll(_overwritten(mine, null));
        await _applier.deleteRecording(id);
        _bookkeeping.remove('recordings', id);
        out.tombstones++;
        continue;
      }
      if (state != null && serverVersion <= state.serverVersion) continue; // already have it
      final Recording? theirs = SyncRowCodec.recordingFromRow(row, local: mine);
      if (theirs == null) { out.skipped++; continue; }

      Recording next = theirs;
      if (mine != null && dirty) {
        out.conflicts++;
        revisions.addAll(_overwritten(mine, theirs));
      }
      // Transcript never shrinks.
      if (mine?.transcript != null && (theirs.transcript == null || theirs.transcript!.length < mine!.transcript!.length)) {
        next = theirs.copyWith(transcript: mine!.transcript);
        out.redirtied.add(next);
        _bookkeeping.put('recordings', id, serverVersion, 'redirtied');  // hash mismatch on purpose
      } else {
        _bookkeeping.put('recordings', id, serverVersion, SyncRowCodec.hash(SyncRowCodec.recording(next)));
      }
      upserts.add(next);
      out.pulled++;
    }
    if (revisions.isNotEmpty) await _applier.appendRevisions(revisions);
    if (upserts.isNotEmpty) await _applier.upsertRecordings(upserts);
  }

  /// One revision per field the server value replaces. `theirs == null` is a
  /// tombstone: every non-empty local field is recorded as lost.
  List<RecordingRevision> _overwritten(Recording mine, Recording? theirs) {
    final DateTime at = _clock();
    RecordingRevision? diff(String field, String? from, String? to) {
      if (from == null || from.isEmpty || from == to) return null;
      return RecordingRevision(recordingId: mine.id, at: at, field: field,
        from: RecordingRevision.truncate(from), to: RecordingRevision.truncate(to), source: RevisionSource.sync);
    }
    return <RecordingRevision>[
      diff('title', mine.title, theirs?.title),
      diff('category', mine.category?.name, theirs?.category?.name),
      diff('summary', mine.summary, theirs?.summary),
      diff('tags', mine.tags.join(', '), theirs?.tags.join(', ')),
      diff('transcript', mine.transcript, theirs?.transcript),
    ].whereType<RecordingRevision>().toList();
  }
```

The five fields mirror `CaptureHistory.recordRevisions` exactly — same names, same `truncate`, same "a change out of an empty value is never recorded" rule.

`_applySimple` decodes each row, skips nulls (`out.skipped++`), bookkeeps `(version, hash)`, counts `pulled`, and hands the list to the applier. `_applyRevisions` decodes with `revisionFromRow`, skips nulls, and calls `appendRevisions` — `RevisionsRepository.append` is line-appended and the backup import already dedupes identical lines, but the engine must not re-append what it has: bookkeep each revision's row id with version 0 and skip ids already known.

- [ ] **Step 4: Run** — `flutter test test/sync/` → all PASS; `flutter analyze` clean. Break the transcript rule (`<` → `<=` is not enough; remove the branch) and watch "transcript never shrinks" fail; restore.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add lib/features/sync test/sync
git -C <worktree> commit -m "feat(sync): add the sync engine pull side and conflict rules

Refs #194"
```

---

### Task 8: `SupabaseSyncTransport`

**Files:**
- Create: `lib/features/sync/data/supabase_sync_transport.dart`
- Test: none unit (thin adapter); end-to-end in Task 10.

**Interfaces:**
- Consumes: `SupabaseClient` (from `Supabase.instance.client`), `SyncTransport`.
- Produces: `SupabaseSyncTransport(SupabaseClient client)`.

- [ ] **Step 1: Write it**

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';

/// PostgREST + the `sync_push` RPC. The only file in the feature that imports
/// `supabase_flutter`; everything above it is testable without a network.
class SupabaseSyncTransport implements SyncTransport {
  SupabaseSyncTransport(this._client);

  final SupabaseClient _client;

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const SyncPushResult(applied: 0, conflicts: <Map<String, Object?>>[]);
    final Object? raw = await _client.rpc<Object?>(
      'sync_push',
      params: <String, Object?>{'table_name': table.name, 'rows': rows},
    );
    if (raw is! Map) throw StateError('sync_push answered ${raw.runtimeType}');
    final Object? conflicts = raw['conflicts'];
    return SyncPushResult(
      applied: raw['applied'] is int ? raw['applied'] as int : 0,
      conflicts: <Map<String, Object?>>[
        if (conflicts is List)
          for (final Object? c in conflicts)
            if (c is Map) Map<String, Object?>.from(c),
      ],
    );
  }

  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit}) async {
    final DateTime upper = (await serverNow()).subtract(syncLagWindow);
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
        _client.from(table.name).select().lte('updated_at', upper.toIso8601String());
    if (since != null) {
      query = query.gt('updated_at', since.subtract(syncLagWindow).toIso8601String());
    }
    final List<Map<String, dynamic>> rows = await query
        .order('updated_at', ascending: true)
        .order(table.keyColumns.first, ascending: true)
        .range(offset, offset + limit - 1);
    return SyncPage(
      rows: <Map<String, Object?>>[for (final Map<String, dynamic> r in rows) Map<String, Object?>.from(r)],
      hasMore: rows.length == limit,
    );
  }

  @override
  Future<DateTime> serverNow() async {
    // PostgREST has no clock endpoint; `now()` through a tiny RPC is
    // cheaper than a round trip per table, so `sync_push` ships with it.
    final Object? raw = await _client.rpc<Object?>('sync_now');
    return raw is String ? DateTime.parse(raw).toUtc() : DateTime.now().toUtc();
  }
}
```

- [ ] **Step 2: Add `sync_now` to the Task 1 migration** (same file, append):

```sql
create or replace function public.sync_now() returns timestamptz
language sql stable security invoker set search_path = '' as $$ select now() $$;
revoke all on function public.sync_now() from public, anon;
grant execute on function public.sync_now() to authenticated;
```

and one pgTAP line: `select ok((select public.sync_now()) <= now(), 'sync_now answers server time');` (bump `plan`). `supabase db reset && supabase test db` → PASS.

- [ ] **Step 3: `flutter analyze`** clean. Check the exact PostgREST builder types against `supabase_flutter` 2.17 — `select()` without arguments returns all columns; if the generic type on `PostgrestFilterBuilder` does not line up, drop the annotation and let inference decide.

- [ ] **Step 4: Commit**

```bash
git -C <worktree> add lib/features/sync/data/supabase_sync_transport.dart supabase
git -C <worktree> commit -m "feat(sync): add the postgrest sync transport

Refs #194"
```

---

### Task 9: Wiring — coordinator, controller, device id, launch run, copy, docs

**Files:**
- Modify: `lib/core/sync/cloud_sync_coordinator.dart` (third slot + result + message)
- Modify: `lib/features/recordings/presentation/recordings_controller.dart:653-720` (`_performCloudSync`)
- Modify: `lib/features/settings/domain/app_settings.dart` (`syncDeviceId`) + its round-trip test
- Create: `lib/features/sync/data/repository_sync_applier.dart` (`SyncApplier` over the real repositories)
- Modify: `lib/app/app.dart` (launch run when signed in)
- Modify: `lib/features/settings/presentation/sync_section.dart` (hint copy)
- Modify: `test/widget/config_tab_test.dart` (copy assertion)
- Create: `docs/architecture/sync.md`; Modify: `CLAUDE.md` (table row + feature line)
- Test: `test/cloud_sync_coordinator_test.dart` (existing; extend)

**Interfaces:**
- Consumes: `SyncEngine`, `SupabaseSyncTransport`, `SyncRowsStore`, `RecordingsRepository.loadAll/saveAll`, `ProjectsRepository.loadAll/saveAll`, `ClipboardRepository.getItems/addItem/updateItemText/deleteItem`, `RevisionsRepository.append`, `RecordingsController.deleteRecording`.
- Produces: `CloudSyncCoordinator({syncSupabase})`, `CloudSyncReport.supabase`, `AppSettings.syncDeviceId`, `RecordingsController.syncCloud()` covering Supabase when `authGateway.currentIdentity != null`.

- [ ] **Step 1: Coordinator test first** — extend `test/cloud_sync_coordinator_test.dart`:

```dart
  test('supabase result rides beside turso and r2 in the report', () async {
    final CloudSyncCoordinator c = CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(pushed: 2, pulled: 1),
    );
    final CloudSyncReport report = await c.sync();
    expect(report.success, isTrue);
    expect(report.message, contains('Supabase: 2 pushed · 1 pulled'));
  });

  test('a supabase failure makes the report fail with its reason', () async {
    final CloudSyncCoordinator c = CloudSyncCoordinator(
      syncSupabase: () async => const SupabaseSyncResult(failureReason: 'offline'),
    );
    final CloudSyncReport report = await c.sync();
    expect(report.success, isFalse);
    expect(report.message, contains('Supabase: offline'));
  });
```

Run → FAIL (no `syncSupabase`). Add the slot, the `supabase` field, extend `success`/`partialSuccess` to three-way, and add the message line: `Supabase: N pushed · N pulled[ · N conflicts][ · N removed][ · N skipped]` or `Supabase: <reason>`. Run → PASS. Commit `feat(sync): report supabase sync beside turso and r2`.

- [ ] **Step 2: `syncDeviceId` on `AppSettings`** — extend the settings round-trip test: absent in legacy JSON → `null`; set → survives `toJson`/`fromJson`. Add the nullable `String? syncDeviceId` field, `copyWith`, JSON key `syncDeviceId`. Commit `feat(settings): persist a sync device id`.

- [ ] **Step 3: `RepositorySyncApplier`** — `lib/features/sync/data/repository_sync_applier.dart`:

```dart
class RepositorySyncApplier implements SyncApplier {
  RepositorySyncApplier({
    required RecordingsRepository recordings,
    required ProjectsRepository projects,
    required ClipboardRepository clipboard,
    required RevisionsRepository? revisions,
    required Future<void> Function(String id) deleteRecording,
  });

  @override
  Future<void> upsertRecordings(List<Recording> rows) async {
    final List<Recording> all = await _recordings.loadAll();
    final Map<String, Recording> byId = {for (final r in all) r.id: r};
    for (final Recording r in rows) byId[r.id] = r;
    final List<Recording> merged = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _recordings.saveAll(merged);
  }
  // upsertProjects: loadAll → merge by id → saveAll(projects, activeProjectId: <read from repository>)
  // upsertClipboardItems: for each row, existing id → updateItemText(id, text) when text differs, else addItem
  // appendRevisions: _revisions?.append(rows)
  // deleteRecording: the callback
}
```

Check `ProjectsRepository.saveAll`'s `activeProjectId` source (`loadActiveProjectId()` or similar) and keep it unchanged. `saveAll` through `RecordingsRepository` honours `_indexUnreadable` — when the index is unreadable the save throws, the engine reports the failure, nothing is lost. Commit `feat(sync): apply pulled rows through the repositories`.

- [ ] **Step 4: Controller wiring** — in `RecordingsController`:
  - new constructor params: `SyncTransport Function()? syncTransportResolver` (resolver, not snapshot — seam rule), `AuthGateway? authGateway`, `ProjectsRepository? projectsRepository`, `ClipboardRepository? clipboardRepository`, `String Function()? appVersion`.
  - in `_performCloudSync`, after `hasR2`: `final bool hasSupabase = authGateway?.currentIdentity != null && syncTransportResolver != null;` and a third slot:

```dart
      syncSupabase: hasSupabase
          ? () async {
              final SyncRowsStore store = SyncRowsStore(db.rawDatabase);
              final String deviceId = await _ensureDeviceId(settings);
              final SyncSnapshot snapshot = SyncSnapshot(
                recordings: List<Recording>.of(_recordings),
                projects: await projectsRepository!.loadAll(),
                clipboardItems: await clipboardRepository!.getItems(),
                revisions: _history.allRevisions(),
                device: SyncRowCodec.device(id: deviceId, name: Platform.localHostname, platform: Platform.operatingSystem, appVersion: appVersion?.call()),
              );
              return SyncEngine(
                transport: syncTransportResolver!(),
                bookkeeping: store,
                applier: RepositorySyncApplier(
                  recordings: _repository, projects: projectsRepository!, clipboard: clipboardRepository!,
                  revisions: _revisionsRepository, deleteRecording: deleteRecording,
                ),
              ).run(snapshot);
            }
          : null,
```

  `AppDatabase` needs a `Database get rawDatabase` (or pass `db` into `SyncRowsStore` the way the existing services take `db: db` — match whichever `TursoSyncService(db: db)` does). `_ensureDeviceId` reads `settings.syncDeviceId`, generates `const Uuid().v4()` when null and saves through `SettingsRepository`. `CaptureHistory.allRevisions()` — add a getter returning the flat list it already holds. `reloadFromStorage()` already runs after the coordinator, so pulled rows reach the queue.
  Commit `feat(sync): run supabase sync from sync now when signed in`.

- [ ] **Step 5: App wiring** — in `lib/app/app.dart` where `RecordingsController` is built: pass `syncTransportResolver: () => SupabaseSyncTransport(Supabase.instance.client)` only when Supabase was initialised (the same condition that builds `AuthController`), `authGateway`, both repositories, `appVersion`. After the controller's initial load, `if (authController?.identity != null) unawaited(controller.syncCloud())` — best-effort, errors already swallowed inside `syncCloud`. Commit `feat(sync): sync once at launch when signed in`.

- [ ] **Step 6: Copy** — `sync_section.dart` hint: replace "carries sign-in only — it does not sync captures yet" with "syncs capture metadata when you are signed in; media files still travel through R2 until the next slice". Update the assertion in `test/widget/config_tab_test.dart` that pins the old text. `flutter test test/widget/config_tab_test.dart` → PASS. Commit `docs(settings): say what the account syncs`.

- [ ] **Step 7: Docs** — `docs/architecture/sync.md`: one page, written to be read whole, covering the snapshot diff, the version gate, the lag window, the apply table, the transcript rule, the tombstone path, and the two things a future change must not do (raw SQL on pull; sending `owner_id`). Add a row to CLAUDE.md's reference table (`docs/architecture/sync.md` — `features/sync/`, `sync_push`, `sync_rows`, the cursor) and a `sync` line under "The features" (sixteen → seventeen). Update the `auth` line's "no cloud-data transport belongs here yet" to point at `features/sync/`. Commit `docs(sync): add the sync reference`.

- [ ] **Step 8: Gate** — `flutter analyze` clean, `flutter test` green, `supabase test db` PASS.

---

### Task 10: End-to-end against the local stack

**Files:** none committed; the PR body carries the transcript.

- [ ] **Step 1:** `supabase status -o json` → `API_URL`, `ANON_KEY`. Create two users through the local GoTrue admin API (`SERVICE_ROLE_KEY` from status, never in the app):

```bash
curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" -d '{"email":"a@example.com","password":"password-a","email_confirm":true}'
```

- [ ] **Step 2:** A throwaway Dart script under the scratchpad (not the repo) that signs in with email/password via `SupabaseClient`, builds `SyncEngine(transport: SupabaseSyncTransport(client), bookkeeping: MemoryBookkeeping(), applier: RecordingApplier())` and runs: push one recording as A; pull as B (expect 0); push a conflicting version as A from a second engine instance (expect 1 conflict, revision recorded); tombstone; pull as A on a fresh engine (expect the tombstone applied). Quote the counts in the PR.

- [ ] **Step 3:** Run the desktop app once against the local stack with `--dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_PUBLISHABLE_KEY=$ANON_KEY`, sign in, press SYNC NOW, screenshot the report line. **The app runs against the real library — read the memory note on live data before clicking anything else.** If that is not acceptable, skip this step and say so in the PR.

- [ ] **Step 4:** Push branch (pre-push hook), reviewer pass on the full diff, PR with `Closes #194`, the verification limit paragraph from the spec, and the note that hosted still needs `supabase db push`.

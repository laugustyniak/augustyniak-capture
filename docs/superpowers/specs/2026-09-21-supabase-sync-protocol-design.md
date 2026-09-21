# Supabase sync protocol — outbox/inbox metadata synchronisation

Slice 3 of #187. Builds on the schema from #190 (PR #192): seven user-owned
tables, `(owner_id, id)` keys, forced RLS, no `delete` grant, client-owned
`version`, server-stamped `updated_at`.

## Goal

Every signed-in device converges on the same metadata — recordings, segments,
projects, clipboard items, revisions, devices, sync state — without ever
issuing `INSERT OR REPLACE`, without ever losing an edit silently, and without
weakening either durability invariant. Media bytes are slice 4; a pulled
recording arrives as metadata whose source file is absent until then.

## Non-goals

- Media upload/download (slice 4).
- First-login migration of pre-existing local data to the account (slice 5).
  This slice pushes whatever the device holds, which *is* the migration for a
  device that was already signed in; the explicit "adopt this library" flow is
  later.
- Automatic post-capture push. Sync runs from SYNC NOW and once at launch.
- Retiring Turso/R2 (slice 6). Both keep working beside this.

## Change detection: snapshot diff

No hooks at mutation sites and no new field on `Recording`. A new SQLite table
in `app_database.dart` holds per-row sync state:

```sql
CREATE TABLE IF NOT EXISTS sync_rows (
  table_name     TEXT    NOT NULL,
  id             TEXT    NOT NULL,   -- composite ids joined with '/'
  server_version INTEGER NOT NULL,   -- last version the server acknowledged
  pushed_hash    TEXT    NOT NULL,   -- sha256 of the canonical row we pushed
  PRIMARY KEY (table_name, id)
);
```

SQLite is not part of the backup archive and is per install, so this state is
device-local by construction — it never travels with a restore and never
appears in `recordings.json`.

At sync time each local row is canonicalised to the exact JSON object the
server table stores (column names, ISO-8601 UTC timestamps, sorted keys) and
hashed. Three outcomes per id:

| local | `sync_rows` | outcome |
| --- | --- | --- |
| present, hash ≠ `pushed_hash` | any | **dirty** → push at `server_version + 1` (1 when absent) |
| present, hash = `pushed_hash` | present | clean, nothing to push |
| absent | present | **locally deleted** → push tombstone (`deleted_at = now()`) at `server_version + 1` |

A crashed or partial push is harmless: the next run re-diffs and re-pushes the
same rows at the same versions, and the server's version gate makes the retry
idempotent.

Composite-key tables (`segments`, `revisions`, `sync_state`) use the key
columns joined with `/` as the `sync_rows.id`.

## Transport: one RPC, version-gated, RLS intact

Migration `supabase/migrations/<ts>_sync_push.sql` adds:

```sql
create function public.sync_push(table_name text, rows jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
```

`security invoker` is load-bearing: the policies from #190 keep applying, so
the function can only ever touch the caller's rows. `owner_id` is never read
from the payload — the column default fills it and the trigger from #190
refuses any later change. `table_name` is validated against the seven known
names before it reaches `format()`.

Per row the function runs, for the six versioned tables:

```sql
insert into public.<t> (…columns from the payload…)
values (…)
on conflict (owner_id, <key columns>) do update
  set …every payload column…
  where <t>.version = excluded.version - 1
```

and collects each row whose insert-or-update touched nothing. For `revisions`
it runs `insert … on conflict do nothing` — no version, no update grant —
and a no-op is not a conflict.

The return value is `{"applied": n, "conflicts": [{…server row…}, …]}`: the
caller gets the server's current row for every gate that failed, so it can
resolve without a second round trip.

Batch size is 200 rows per call. pgTAP (`supabase/tests/sync_push_test.sql`)
covers: insert at version 1; update at version 2 over server 1; push version 2
over server 3 returns the server row as a conflict and changes nothing;
tombstone via version gate; revisions no-op on the natural key; B pushing an id
A holds creates B's own row, never touches A's; an unknown `table_name` raises.

## Pull: server cursor with a lag window

Per table the client asks, paged by 500 and ordered `(updated_at, id)`:

```sql
updated_at >  cursor - interval '30 seconds'
and updated_at <= now() - interval '30 seconds'
```

`updated_at` is transaction-start time. A push that commits *after* another
device's pull has read past its stamp would be skipped by a naive
`updated_at > cursor`. Re-reading the last 30 seconds each time covers any
transaction that ran shorter than that, and the version-gated apply below makes
the re-read idempotent — an already-applied row is clean and equal, so it is a
no-op. The upper bound keeps the window closed: rows stamped inside the last
30 seconds are picked up next time, never half-seen.

The cursor per table is the greatest `updated_at` seen, stored locally in the
SQLite `settings` table under `sync.cursor.<table>` and mirrored to the
server's `sync_state` row for this device so a reinstall can see where its
predecessor stopped.

## Apply: through the repository, never raw SQL

The Turso path writes SQLite directly and then `reloadFromStorage()`; that is
the shape the index/mirror divergence machinery exists to catch. This path
loads through `RecordingsRepository`, merges in memory, and `saveAll`s once per
table per run. The same for `ProjectsRepository`, `ClipboardRepository`, and
`RevisionsRepository.append`.

For each pulled row, keyed by the local hash state:

| local state | server row | action |
| --- | --- | --- |
| absent | live | insert; `sync_rows` ← (version, hash) |
| clean | live | replace; `sync_rows` ← (version, hash) |
| dirty | live, version = ours | ours is newer; leave it, the push side will send it |
| dirty | live, version > ours | **server wins.** Each field the server value overwrites is appended as `RecordingRevision(source: RevisionSource.sync)`; then replace; `sync_rows` ← (version, hash) |
| any | `deleted_at` set | if dirty, write revisions first so HISTORY shows what was thrown away; then the `deleteRecording` callback the engine was constructed with — bound to `RecordingsController.deleteRecording()`, the locked removal path, source file included; `sync_rows` row removed |

A pulled tombstone is the user's own intent from another device, not a cloud
failure, which is why it may reach the source file. It runs through the same
entry point the delete button calls and nothing else.

**`transcript` never shrinks.** It accumulates per the segments rule and a
pull may never shorten it. A server transcript shorter than the local one is
treated as a per-field conflict the local side wins: the local transcript is
kept, the row is marked dirty and re-pushed. Every other field follows the
table above.

`RevisionSource.sync` is a new enum value. `fromName(unknown)` already
degrades to the legacy default, so an older build reading the file is fine.

Push runs first, then pull, then push again only if the pull marked rows
dirty (the transcript rule). Conflicts returned by `sync_push` are applied
with the same table as pulled rows.

## Seam

```
lib/features/sync/
  domain/sync_transport.dart      SyncTransport (push, pull, cursor)
                                  DisabledSyncTransport — throws at use
  domain/sync_row_codec.dart      canonical JSON + hash per table
  domain/sync_engine.dart         diff, apply, conflict rules (pure Dart)
  data/supabase_sync_transport.dart  PostgREST + RPC, the only file that
                                  imports supabase_flutter
```

`SyncEngine` is constructed with a `SyncTransport`, the repositories, the
`sync_rows` store and a `deleteRecording` callback (the engine never imports
the controller), and returns a `SupabaseSyncResult` (pushed, pulled,
conflicts, tombstones applied, failure reason). `CloudSyncCoordinator` gains a
third slot, `syncSupabase`, and `CloudSyncReport` a third result; the report's
`message` names it beside Turso and R2.

Device identity: a uuid generated once and stored in `settings` under
`syncDeviceId`; the `devices` row is upserted on every run with
`last_seen_at` and the app version.

## Triggers

- SYNC NOW routes to Supabase when a session exists, alongside whatever legacy
  providers are configured.
- One run at launch when a session exists, `unawaited`, best-effort — the
  sink contract.
- Nothing runs signed out. Nothing blocks capture.

`LegacySyncSection`'s hint that the account "does not sync captures yet" is
updated: metadata syncs, media follows in slice 4.

## Failure handling

- Any transport failure ends the run with `failureReason`; nothing local is
  changed for that table. Tables are independent — a failure in
  `clipboard_items` does not roll back an applied `recordings` pull.
- A server row that fails to decode is skipped and counted, never fatal
  (degrade on load).
- Sync never marks a recording `failed`, never touches `status`, never deletes
  except through the tombstone rule above.
- The run holds `_cloudSyncInFlight` like the existing sync, so two SYNC NOW
  presses do not race.

## Tests

Pure Dart, fake transport in memory (`test/sync/`):

- dirty detection: unchanged row is not pushed; edited row is; deleted row
  becomes a tombstone at the right version
- conflict: server ahead → local replaced, revisions written for each
  overwritten field, `sync_rows` updated
- tombstone pull: dirty local → revisions then delete; clean local → delete
- transcript never shrinks: shorter server transcript → local kept, row dirty,
  re-pushed
- cursor lag: a row inside the window applied twice is a no-op
- decode failure: one bad row skipped, the rest applied, count reported
- composite ids round-trip for segments, revisions, sync_state

pgTAP for `sync_push` as listed above.

One end-to-end run against the local stack (`supabase start`,
`SUPABASE_URL=http://127.0.0.1:54321`), two fake users, documented in the PR.

## Verification limit

The hosted project has neither #192's schema nor this RPC until
`supabase db push` runs, which needs an explicit go-ahead. "A fresh
installation can restore the authenticated user's synchronised captures"
cannot be demonstrated end-to-end before that; everything else is covered
locally.

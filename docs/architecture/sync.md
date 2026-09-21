# Supabase sync

Outbox/inbox metadata synchronisation over Postgres, wired in beside Turso and
R2 rather than replacing either. Slice 3 of #187 (schema from #190). Media
bytes are slice 4 — a pulled recording arrives as metadata whose source file
is absent until then. This file is written to be read whole.

**Every signed-in device converges on the same metadata** — recordings,
segments, projects, clipboard items, revisions, devices, sync state —
without ever issuing `INSERT OR REPLACE`, without losing an edit silently,
and without weakening either durability invariant in the root `CLAUDE.md`.

## Change detection: a device-local ledger, not hooks

No hook at any mutation site and no new field on `Recording`. `sync_rows`
(`app_database.dart`) holds one row per synced id: `table_name`, `id`
(composite ids joined with `/`), `server_version` (the last version the
server acknowledged), `pushed_hash` (sha256 of the canonical row last
pushed). It is per install, not part of the backup archive, and never
appears in `recordings.json`.

At sync time each local row is canonicalised to the exact JSON the server
table stores (column names, ISO-8601 UTC, sorted keys) and hashed:

| local | `sync_rows` | outcome |
| --- | --- | --- |
| hash ≠ `pushed_hash` | any | dirty → push at `server_version + 1` (1 when absent) |
| hash = `pushed_hash` | present | clean, nothing to push |
| absent | present | locally deleted → push a tombstone (`deleted_at = now()`) at `server_version + 1` |

A crashed or partial push is harmless: the next run re-diffs and re-pushes
the same rows at the same versions, and the version gate below makes the
retry idempotent.

## Transport: one RPC, version-gated, RLS intact

`sync_push(table_name, rows)` — `security invoker`, so the RLS policies from
#190 keep applying and the function can only ever touch the caller's own
rows. **`owner_id` is never read from the payload**: the column default
fills it and a trigger refuses any later change, so a client cannot push a
row it does not own no matter what it sends. `table_name` is validated
against the seven known names before it reaches `format()`.

Per row, the six versioned tables run an upsert gated `where version =
excluded.version - 1`; `revisions` runs `insert … on conflict do nothing` —
no version, no update grant, and a no-op is not a conflict. The RPC answers
`{applied, conflicts: [...server rows...], rejected: [...]}` — a conflict is
a well-formed row that lost the version race, a rejection is one the
function could not apply to its table at all (bad cast, missing column).
Batch size is 200 rows per call.

## The engine fuse: an empty outbox is refused, not swept

A versioned table whose outbox is entirely empty while `sync_rows`
bookkeeping for that table is not looks exactly like every row having been
deleted — and diffing an empty local snapshot against non-empty bookkeeping
would otherwise push a tombstone for every one of them. That premise is
almost always a bug upstream (an unindexed read, a controller constructed
against the wrong directory, a snapshot built before `initialize()`
finished) rather than the user actually deleting everything, so
`SyncEngine._pushTable` refuses the sweep instead of performing it: nothing
is pushed for that table, the row stays bookkept for the next run, and the
run's `failureReason` names the table and the row count refused. This is
the push-side analogue of the index's own "a shrink nobody announced is
backed up first" rule in the root `CLAUDE.md` — an empty local state is
never taken silently at face value against non-empty stored state. The fuse
is per table: one table tripping it does not cost a push on any other table
in the same run. It does not fire on a genuinely partial delete (some rows
still present, one gone) — that is the ordinary per-row tombstone path
above — only on the whole table going from non-empty bookkept to empty
outbox in one step.

## Pull: server cursor with a lag window

Paged by 500, ordered `(updated_at, id)`:

```
updated_at >  cursor - 30s
and updated_at <= now() - 30s
```

`updated_at` is transaction-start time, so a push that commits after another
device's pull has read past its stamp would be skipped by a naive `updated_at
> cursor`. Re-reading the last 30 seconds each time covers any transaction
shorter than that; the upper bound keeps the window closed, so a row stamped
inside the last 30 seconds is picked up on the *next* run rather than
half-seen on this one. The version gate makes the overlap a no-op: an
already-applied row is clean and equal.

The cursor per table is the greatest `updated_at` seen, stored locally under
`settings['sync.cursor.<table>']` and mirrored to the server's `sync_state`
row for this device, so a reinstall can see where its predecessor stopped.

## Apply: through the owning controller, never a second writer

**The one rule a future change to this file must not break: apply never
writes underneath a controller that already owns the same state in
memory.** The Turso path writes SQLite directly and then
`reloadFromStorage()` — which is exactly the index/mirror divergence the
durability machinery in the root `CLAUDE.md` exists to catch, and round 1 of
this slice's own review found the same class of bug twice more: a second
`RecordingsRepository`/`ProjectsRepository` instance, writing whatever the
pull side merged, underneath `RecordingsController`/`ProjectsController`'s
own in-memory list. Whichever controller's *own* next mutation persists
next — `_update`, `stopRecording`, `create`, `select` — rewrites its state
wholesale from that stale in-memory copy, silently reverting the pull, with
`sync_rows` already claiming the overwritten rows at the server's version so
they never even re-pull.

So `RepositorySyncApplier` (`features/sync/data/repository_sync_applier.dart`)
does not hold a `RecordingsRepository` or a `ProjectsRepository` at all —
only callbacks bound to the controller that owns each table:

- `applySyncedRecordings` → `RecordingsController.applySyncedRecordings`:
  merges the pulled batch into `_recordings` **in place**, then calls the
  controller's own `_persistAll()` — the same funnel `_update` and
  `stopRecording` use, including its `_saveInFlight` queue. A writer already
  between its own in-memory mutation and its own `_persistAll` when this
  runs is not undone: the merge happens synchronously, before either side's
  `_persistAll` actually reads `_recordings`, so whichever write goes second
  persists the union of both. `docs/architecture/persistence.md`'s
  `updateAll` (load-merge-write under one lock) was tried first and
  rejected — it protects against a *different* writer racing the repository
  underneath both controller and applier, but not against the controller's
  *own* queued writer resuming with a stale `_recordings`, which is the
  actual hazard here.
- `applySyncedProjects` / `applySyncedProjectDelete` →
  `ProjectsController.applySyncedProjects` / `.applySyncedProjectDelete`:
  the same shape — merge or remove against `_projects`, then `_save()`.
  `applySyncedProjectDelete` is `delete` itself, since a pulled tombstone
  needs nothing `delete` does not already do (unknown-id no-op included).
- `deleteRecording` is the controller's own locked removal path, as before
  — but now the applier checks `RecordingsController`'s own list
  (`recordingExists`) after calling it. `RecordingsController.deleteRecording`
  returns normally on a refusal (index unreadable, a source file that would
  not delete) rather than throwing, which is right for a button the user
  can press again — and exactly wrong for a sync tombstone read silently as
  success: without the check, the engine would bookkeep the row as gone and
  never retry it. A refusal throws `StateError` instead, which the engine's
  own `run()` surfaces as `failureReason`, and — because the throw happens
  before `_bookkeeping.remove` runs — leaves the row bookkept for a retry
  next time.
- `upsertClipboardItems` / `deleteClipboardItem` still go straight through
  `ClipboardRepository`, which is safe here on its own: its writes are
  already row-level (`addItem`/`updateItemText`/`deleteItem`), never a
  whole-list rewrite from a captured snapshot, so there is no second-writer
  hazard to close for this table.

For each pulled row, keyed by local hash state:

| local state | server row | action |
| --- | --- | --- |
| absent | live | insert; `sync_rows` ← (version, hash) |
| clean | live | replace; `sync_rows` ← (version, hash) |
| dirty | live, version = ours | ours is newer; leave it, the push side sends it |
| dirty | live, version > ours | **server wins.** Each overwritten field is appended as `RecordingRevision(source: RevisionSource.sync)`; then replace |
| any | `deleted_at` set | if dirty, write revisions first so HISTORY shows what was thrown away; then the `deleteRecording` callback — the locked removal path, source file included; `sync_rows` row removed |

A pulled tombstone is the user's own intent from another device, not a cloud
failure, which is why it may reach the source file: it runs through the same
entry point the delete button calls and nothing else. **Every `delete*` on
`SyncApplier` tolerates an id it has never heard of** — a tombstone for a
row this device never had is a no-op, never a throw.

**`transcript` never shrinks.** It accumulates per the segments rule
(`docs/architecture/capture-pipeline.md`) and a pull may never shorten it. A
server transcript shorter than the local one is a per-field conflict the
local side wins: the local transcript is kept, the row is marked dirty and
re-pushed. Every other field follows the table above.

Push runs first, then pull, then push again only if the pull marked rows
dirty (the transcript rule). Conflicts `sync_push` returns are applied
through the same table as pulled rows, in `SyncEngine._resolvePushConflicts`.

### The lost-write hazard `applySyncedRecordings` closes

`RecordingsController` keeps its own in-memory `_recordings` list, captured
into the `SyncSnapshot` once at the start of a run. The applier no longer
writes `recordings.json` on its own at all — `upsertRecordings` calls
`RecordingsController.applySyncedRecordings(upserts)`, which merges the
pulled batch into `_recordings` **in place** (replace by id, insert new,
re-sort createdAt-desc) and then calls the controller's own `_persistAll()`.
A tombstone in the *same* run goes through `deleteRecording`, the
controller's other funnel onto the identical `_recordings` field — so an
upsert followed by an unrelated tombstone in one run sees the upsert's
merge before the tombstone's removal runs, never a stale copy.

The hazard this closes is not a second sync writer racing the repository —
it is the controller's **own** queued writer. `_update`/`stopRecording`
mutate `_recordings` and then `await _persistAll()`; `_persistAll()` itself
queues behind `_saveInFlight` when another write is already in progress. A
naive fix (apply straight through `RecordingsRepository`, then
`reloadFromStorage()`) loses exactly the write that was queued behind that
lock: `reloadFromStorage()` overwrites `_recordings` with whatever is on
disk *right now*, and the queued writer then resumes with its
already-captured, now-stale copy and persists it wholesale, silently
reverting both the sync pull and its own edit. `applySyncedRecordings`
mutates the same `_recordings` field every other writer mutates, so there
is nothing to go stale — whichever write's `_persistAll` runs second
persists the union of both. `test/sync/applied_recordings_concurrency_test.dart`
proves it against a deliberately slowed `saveAll`.

### Clipboard: a known gap, accepted for this slice

`ClipboardRepository` has no collection-update method, so
`upsertClipboardItems` only ever applies `text`: an existing id gets
`updateItemText` when the pulled text differs, a new id gets `addItem`. A
pulled row's `collections` are silently not applied. `addItem` also
deduplicates against the single most recent local entry (same type, text and
image path) and silently drops a match — a sync-pulled item identical to the
newest local one will not be inserted. Both are pre-existing repository
behaviour, not something this slice changed; fixing either needs a new
`ClipboardRepository` method and is out of scope here.

### Projects: the active id

The same lost-write class applies to `ProjectsController._projects` as to
`RecordingsController._recordings`, so the fix is the same shape:
`upsertProjects` calls `ProjectsController.applySyncedProjects(upserts)`,
which merges by id into `_projects` in place and then `_save()`s — the same
field the controller's own `create`/`update`/`select` mutate, so a pulled
project cannot be reverted by the user's next action reading a stale copy.
`deleteProject` calls `ProjectsController.applySyncedProjectDelete(id)`,
which is `delete` itself: deleting the active project reassigns to the
first remaining one, or to nothing when none remain; deleting any other id,
or one this device never had, leaves the active id untouched — the same
`_resolveActive` logic the delete button already runs, so a pulled
tombstone for the active project cannot leave `_activeProjectId` pointing
at a project that no longer exists.

### A known staleness gap

`CaptureHistory.loadRevisions()` only runs from `RecordingsController.
initialize()`, not from `reloadFromStorage()`. A sync run's `appendRevisions`
writes straight through `RevisionsRepository.append` — durable on disk
immediately — but the in-memory `CaptureHistory._revisions` map that powers
the editor's HISTORY section is not refreshed until the next full launch.
The data is never lost; it is simply not visible in that section until then.

## Seam

```
lib/features/sync/
  domain/sync_transport.dart      SyncTransport (push, pull, cursor)
                                  DisabledSyncTransport — throws at use
  domain/sync_row_codec.dart      canonical JSON + hash per table
  domain/sync_engine.dart         diff, apply, conflict rules (pure Dart)
                                  SyncApplier — the pull-side interface
  domain/sync_snapshot.dart       SyncSnapshot, SupabaseSyncResult, SyncBookkeeping
  data/sync_rows_store.dart       SyncBookkeeping over sync_rows + settings cursors
  data/supabase_sync_transport.dart  PostgREST + the RPC — the only file that
                                  imports supabase_flutter
  data/repository_sync_applier.dart  SyncApplier over the real repositories
```

`SyncEngine` is constructed with a `SyncTransport`, a `SyncBookkeeping`
(`SyncRowsStore(db.rawDb)`) and a `SyncApplier` — never the controller, so
the engine stays pure Dart and testable with an in-memory fake transport.
`run(SyncSnapshot)` returns a `SupabaseSyncResult` (`pushed`, `pulled`,
`conflicts`, `tombstonesApplied`, `skipped`, `failureReason`; `success ==
failureReason == null`).

`CloudSyncCoordinator` gained a third slot, `syncSupabase`, run between
`syncTurso` and `syncR2` for the same reason Turso goes first: a pull may add
recording rows whose media R2 can then fetch. `CloudSyncReport` gained a
`supabase` field, `success`/`partialSuccess` are three-way, and `message`
gets a line: `Supabase: N pushed · N pulled[ · N conflicts][ · N removed][
· N skipped]` on success, `Supabase: <failureReason>` on failure.

`RecordingsController` takes eight new constructor parameters, all
resolvers or seams and all null in every existing call site and every
pure-Dart test — `hasSupabase` in `_performCloudSync` requires every one of
the seven it checks (`appVersion` is optional, read into the `devices` row
only when present) **and** `!_indexUnreadable`, so a corrupt index keeps
the Supabase slot out entirely rather than handing the engine an empty
`_recordings` snapshot against non-empty bookkeeping — the controller-side
half of the same guard the engine fuse above is the push-side half of:

- `syncTransportResolver: SyncTransport Function()?` — a resolver, not a
  snapshot, the seam rule the root `CLAUDE.md` states once: a Config change
  only affects a run started afterwards, never one already in flight.
- `authGateway: AuthGateway?` — `currentIdentity != null` gates the whole
  slot.
- `projectsRepository`, `clipboardRepository` — read once per run to build
  the snapshot; not held by the applier (see Apply above).
- `syncDeviceId: Future<String> Function()?` — resolves to
  `SettingsController.ensureSyncDeviceId()`.
- `applySyncedProjects: Future<void> Function(List<Project>)?`,
  `applySyncedProjectDelete: Future<void> Function(String)?` — wired to
  `ProjectsController.applySyncedProjects`/`.applySyncedProjectDelete`; see
  Apply above.
- `appVersion: String? Function()?` — read into the `devices` row.

Device identity: `AppSettings.syncDeviceId`, a uuid generated once by
`SettingsController.ensureSyncDeviceId()` and persisted through that
controller — **never** written directly from a bare `SettingsRepository`
elsewhere, because `SettingsController` is `settings.json`'s single writer
and holds its own `AppSettings` snapshot; a second writer's save would be
silently dropped the next time the controller persists anything else. The
`devices` row is upserted on every run via `SyncRowCodec.device(id, name,
platform, appVersion)`, keyed on that id.

## Triggers

- SYNC NOW routes to Supabase when a session exists, alongside whatever
  legacy providers are configured — `RecordingsController.syncCloud()`.
- One run at launch when a session exists **and** the index is readable
  (`!controller.isIndexUnreadable`): `RecordingsPage._bootstrap()` calls
  `controller.syncCloud()`, `unawaited` and best-effort (the sink contract),
  deliberately placed *after* `recoverOrphans()` and every other
  index-writing step in that method — racing it against `recoverOrphans()`
  would be the same lost-write hazard `applySyncedRecordings` closes above,
  just against a different writer. `syncCloud()` runs the whole
  `CloudSyncCoordinator`, so the launch run is not Supabase-only: whatever
  of Turso/Supabase/R2 is configured all run once at launch now, not just
  when the user presses SYNC NOW — an accepted behaviour change from
  before this slot existed, since the coordinator does not offer a
  per-provider trigger.
- Nothing runs signed out. Nothing blocks capture.

`LegacySyncSection`'s Config-tab hint used to say the account "does not sync
captures yet"; it now says what actually happens — metadata syncs when
signed in, media still travels through R2 until slice 4.

## Failure handling

- Any transport failure ends the run with `failureReason`; nothing local
  changes for that table. Tables are independent — a failure in
  `clipboard_items` does not roll back an applied `recordings` pull.
- A server row that fails to decode is skipped and counted, never fatal
  (degrade on load, per the root `CLAUDE.md`).
- Sync never marks a recording `failed`, never touches `status`, never
  deletes except through the tombstone rule above.
- `_cloudSyncInFlight` covers Supabase too — it guards `_performCloudSync`
  as a whole, so two SYNC NOW presses, or a SYNC NOW racing the launch run,
  never run two syncs at once.

## Tests

Pure Dart, in-memory fake transport: `test/sync/sync_engine_push_test.dart`,
`test/sync/sync_engine_pull_test.dart`, `test/sync/sync_row_codec_test.dart`,
`test/sync/sync_rows_store_test.dart`, `test/sync/supabase_sync_transport_test.dart`.
`test/sync/repository_sync_applier_test.dart` covers the wiring in this
file: merge-and-replace, an unknown id no-op for every `delete*`, the active
project id preserved and reassigned, clipboard existing-id-updates-text vs.
new-id-adds. `test/cloud_sync_coordinator_test.dart` covers the third slot
riding beside Turso and R2. pgTAP for `sync_push` lives in
`supabase/tests/`.

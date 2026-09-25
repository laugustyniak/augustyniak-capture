# Supabase sync

Outbox/inbox metadata synchronisation over Postgres. Slice 3 of #187 (schema
from #190); it replaced the Turso + Cloudflare R2 path, which #202 removed
together with its `augustyniak_sync_v1` QR pairing. Media
bytes follow through private Storage — slice 4, #198, see "Media" below — so
a pulled recording is metadata only until the Storage slot of the same run
fetches its source. This file is written to be read whole.

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

**The fuse applies to `recordings` only.** That is the one table whose false
sweep deletes a source file on another device — the tombstone apply path
runs the real `deleteRecording`. `segments` is a child of `recordings`, and
is genuinely, legitimately empty for every single-fragment capture: deleting
the *only* multi-fragment recording in the library makes its segments outbox
go from non-empty bookkept to empty in one step, exactly like the false
positive above, but the parent `recordings` tombstone already covers those
children — a segments-only fuse would jam that table's push on every
subsequent run for no bug at all. `projects` and `clipboard_items` sweep
normally when empty too: their tombstones reach no source file on another
device, and a real "everything in this table is gone" run (the last project
deleted, `clearHistory()`) must be able to push it rather than refuse
forever. The one residual this leaves: deleting the last recording in the
library makes the *push* side report a refusal (`failureReason` names
`recordings`) until another capture exists to make the outbox non-empty
again — pull still runs in the same call, so nothing else in that run is
held back by it.

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

The cursor per table is the greatest `updated_at` seen — except when this
build skipped a row it could not decode, in which case the cursor holds at
that row's own `updated_at` instead of the newest one seen in the same
page, so the skipped row is re-offered every run until a build that can
decode it comes along (the lag-window re-read above is what makes that
repeat pull safe). Stored locally under `settings['sync.cursor.<table>']`
and mirrored to the server's `sync_state` row for this device, so a
reinstall can see where its predecessor stopped.

**Paging is keyset, not offset (#195).** Each page continues strictly
after the previous page's last `(updated_at, key…)` tuple
(`SupabaseSyncTransport.keysetFilter`), spelled out as a nested PostgREST
`or(updated_at.gt.T, and(updated_at.eq.T, k1.gt.V1), …)` because PostgREST
has no row-value comparison. Offset paging skipped a row: when another
device updated a row already returned on an earlier page, that row moved
later in the order, every row behind it shifted one position earlier, and
the row at the next page boundary was never read. With keyset paging the
moved row only moves itself. It is read again later in the same run if its
new `updated_at` is still inside the window, or on the next run through
the lag-window re-read. Every value in the filter is double-quoted, since
`revisions.field` and `sync_state.table_name` are free text. `updated_at`
is passed back exactly as the server returned it, so `eq` keeps
microsecond precision.

## Apply: through the owning controller, never a second writer

**The one rule a future change to this file must not break: apply never
writes underneath a controller that already owns the same state in
memory.** The retired Turso path wrote SQLite directly and then
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

**A live push racing a tombstone always loses to the tombstone**: deletion
beats a concurrent edit. The editing device is still bookkept at the
version before the delete, so its own push of the edit conflicts —
`sync_push` returns the current (deleted) row, and that conflict is applied
through the same path as a pulled row above, so the editing device adopts
the tombstone and deletes locally on its next pull (or immediately, via the
conflict-resolution path in the same run). There is no path through the
engine where an edit lands on a row another device already tombstoned.

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
`updateItemText` when the pulled text differs, a new id gets `insertItem`. A
pulled row's `collections` are silently not applied — pre-existing
repository behaviour, not something this slice changed; fixing it needs a
new `ClipboardRepository` method and is out of scope here. A new id goes
through `insertItem`, not `addItem`: `addItem`'s adjacent-content dedupe
(same type, text and image path as the single most recent local entry)
silently drops a pulled item identical to the newest local one, while this
applier still bookkept it as applied — the next run then saw the id missing
from the outbox and pushed a tombstone for another device's row.
`insertItem` inserts by id with no dedupe and no-ops only when that id is
already present.

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

`applySyncedRecordings` merges into `_recordings` and calls `_persistAll()`
directly — it does not go through `_update`, so a pulled upsert also
bypasses `_mirrorToVault` (the markdown mirror sees a pulled edit only once
`reloadFromStorage()` or the next full launch re-reads it, same as HISTORY
above) and the gamification totals (`GamificationController` only ever
counts what `_update`/`stopRecording` etc. route through it — a pulled
capture is never double-counted, but it is also never counted at all on the
receiving device).

## Media: private Storage, verified before it lands

Slice 4 of #187 (#198). The second `CloudSyncCoordinator` slot, `syncMedia`,
runs after `syncSupabase`: the metadata pull is what adds
the rows whose sources it fetches, so it reads `_recordings` **at call time**,
never the `SyncSnapshot` the metadata slot captured before its pull. It is
wired only when `hasSupabase` is and `mediaStoreResolver` is non-null, and it
never triggers `reloadFromStorage()` — it writes source files, never the index
behind the controller's back.

**The bucket.** `captures`, private
(`supabase/migrations/20260923090000_capture_media_bucket.sql`). Object keys
are `<auth.uid()>/captures/<recording id>/<file name>`; `SupabaseMediaStore`
adds the owner prefix, and the bucket's `select`/`insert` policies compare
that first folder with `auth.uid()`, so a client can only reach its own
objects whatever key it sends. There is no `update` policy (objects are
write-once, so an upload can never replace a source another device already
verified) and no `delete` policy yet: a tombstoned capture's objects stay in
the bucket, private to their owner, until a later change removes them.
`supabase/tests/capture_media_bucket_test.sql` pins all of it.

**Step 0 — names only.** `SyncRowCodec.recordingFromRow` keeps only the
file name of every path a server row carries (`file_path`, `thumbPath`, each
segment's `filePath`) unless a local row already supplies this device's own
path. So an absolute path in `_recordings` was always written by this
device, and a row can never make it download to — or upload from — a
location of the row's choosing.

**Step 1 — re-root.** `RecordingsController._rerootSyncedPaths` points every
bare-name path a pull left behind (`SyncRowCodec.recordingFromRow` with no
local row) into this device's recordings directory — `filePath`, each stored
segment's `filePath`, `thumbPath` — keeping only the name
(`SyncPathPolicy.localFileName`), so a pulled row cannot point outside the
directory; a row whose paths do not actually change is left alone, so an
unusable name never costs an index rewrite per run. It is the `applySyncedRecordings` shape: an in-place merge into
`_recordings`, then `_persistAll()`. The codec basenames these paths on the
way out, so a re-rooted row hashes the same and is not re-pushed. It also
covers rows pulled by a build from before this slice.

**Step 2 — transfer.** `MediaSyncService` (`features/sync/domain/media_sync.dart`,
pure Dart over the `MediaObjectStore` seam) walks every segment of every
recording (`MediaSyncJob.forRecordings`, which skips unsafe ids and paths
that are still not absolute):

| local source | object | outcome |
| --- | --- | --- |
| present, non-empty | present | `unchanged` |
| present, non-empty | absent, local sha256 = `contentHash` | upload (`upsert: false`, sha256 in metadata) → `uploaded`; a racing duplicate counts `unchanged` |
| present, non-empty | absent, sha256 ≠ `contentHash` or none | `waiting` — never uploaded: the bucket is write-once, so a take still being finalised would pin the wrong bytes for every other device |
| absent | any, `contentHash` null, or the path lies outside the recordings directory | `unverifiable` — never downloaded |
| absent | absent | `waiting` — the capturing device has not uploaded yet; not a failure |
| absent | present | download → non-empty **and** sha256 = the synced `contentHash` → `.part` beside the target, flushed → the row still exists (`stillWanted`) → renamed → `downloaded`; otherwise `rejected`, nothing written |

A transfer that throws is counted `failed` and the pass moves on, so one
object the server refuses (a size limit, a bad key) never holds back every
older capture behind it; only an unreachable store or a timeout ends the pass.
`SupabaseMediaStore` translates a lost connection into
`MediaStoreUnreachableException` in both shapes it arrives in — raw
(`package:http`'s `ClientException`, `SocketException`) and folded by
`storage_client` into a `StorageException` whose `statusCode` names the
original error type (`test/sync/supabase_media_store_test.dart`). The
`stillWanted` check exists because a capture deleted while its download was
in flight would otherwise be written back with no row, and `findOrphans`
would re-adopt it as a new capture at the next launch. It is asked before
the rename and again after it, and it treats an id `deleteRecording` is
still working on (`_deleting`) as gone, so a delete that overlaps the
rename cannot miss the file either. The `downloadRoot` check covers rows an
older build persisted with an absolute path before Step 0 existed: such a
row is still uploaded from, but never written to.

The hash a download is checked against is the row's own `contentHash`, which
travelled through the version-gated RPC — not the object's metadata. A
`rejected` download or a `failed` transfer fails the slot (`success` is false); `waiting` and
`unverifiable` only show in the counts. The report line is
`Storage: N uploaded · N downloaded · …`.

**Step 3 — hand-off.** When anything downloaded, `_performCloudSync` calls
`resumeInterruptedProcessing()` — after its own `reloadFromStorage()`, never
before, since a reload landing between the drain's in-memory update and its
persist would drop that write. That is the whole hand-off: the existing
funnel already filters by status, so a `completed` row pulled with its
transcript only gains a playable source, and a row pushed mid-pipeline
(`pendingTranscription`/`transcribing`) is now enqueued here — the guard in
`_enqueueProcessing` that refused it had only ever been waiting for this file.
Such a row is processed on both devices if both still hold it mid-pipeline;
the `transcript` never-shrinks rule settles the result.

One case the hand-off does not reach: appending a fragment to a pulled
`completed` row while one of its earlier fragments is still `waiting`. The
guard refuses the enqueue (every segment must be here) and the row keeps
`completed`, which the resume sweep does not pick up, so the new fragment is
not transcribed until something enqueues the row again.

**Known gaps.** `storage_client` 2.8.0's `download()` answers the whole object
as bytes, so a download holds the file in memory once, and there is no
resumable (TUS) transfer — #187's resumable-transfer item stays open. Objects
of a deleted capture are not removed from the bucket yet.

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
  domain/media_sync.dart          MediaSyncService, MediaSyncJob, MediaObjectStore
                                  DisabledMediaObjectStore — throws at use
  data/supabase_media_store.dart  the private `captures` bucket
```

`SyncEngine` is constructed with a `SyncTransport`, a `SyncBookkeeping`
(`SyncRowsStore(db.rawDb)`) and a `SyncApplier` — never the controller, so
the engine stays pure Dart and testable with an in-memory fake transport.
`run(SyncSnapshot)` returns a `SupabaseSyncResult` (`pushed`, `pulled`,
`conflicts`, `tombstonesApplied`, `skipped`, `failureReason`; `success ==
failureReason == null`).

`CloudSyncCoordinator` runs `syncSupabase` first, because its pull may add
recording rows whose media `syncMedia` then fetches. `CloudSyncReport` carries
a `supabase` field beside `media`, and `message` gets a line: `Supabase: N pushed · N pulled[ · N conflicts][ · N removed][
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
- `syncDeviceId: Future<String?> Function()?` — resolves to
  `SettingsController.ensureSyncDeviceId()`, which is null when
  `SettingsController.initialize()` never actually loaded settings; the
  Supabase slot then reports `failureReason: 'sync skipped: settings
  unavailable'` rather than minting an id and persisting it over
  `AppSettings.empty`.
- `applySyncedProjects: Future<void> Function(List<Project>)?`,
  `applySyncedProjectDelete: Future<void> Function(String)?` — wired to
  `ProjectsController.applySyncedProjects`/`.applySyncedProjectDelete`; see
  Apply above.
- `appVersion: String? Function()?` — read into the `devices` row.
- `mediaStoreResolver: MediaObjectStore Function(String ownerId)?` — added
  with the Storage slot (see Media above); built per run for the signed-in
  user's id. Null keeps that slot out, and it is not one of the seven
  `hasSupabase` checks.

Device identity: `AppSettings.syncDeviceId`, a uuid generated once by
`SettingsController.ensureSyncDeviceId()` and persisted through that
controller — **never** written directly from a bare `SettingsRepository`
elsewhere, because `SettingsController` is `settings.json`'s single writer
and holds its own `AppSettings` snapshot; a second writer's save would be
silently dropped the next time the controller persists anything else. The
`devices` row (`SyncRowCodec.device(id, name, platform, appVersion)`, keyed
on that id) is hash-diffed like every other table, not upserted every run —
so `last_seen_at` only ever holds the timestamp of the run that first
inserted or last changed the row, not this run's time; a row per run would
be noise the server never reads back.

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
  `CloudSyncCoordinator`, so the launch run covers both the metadata and
  the Storage slot, exactly as SYNC NOW does.
- Nothing runs signed out. Nothing blocks capture.

## Failure handling

- Any transport failure ends the run with `failureReason`; nothing local
  changes for that table. Tables are independent — a failure in
  `clipboard_items` does not roll back an applied `recordings` pull.
- A server row that fails to decode is skipped and counted, never fatal
  (degrade on load, per the root `CLAUDE.md`).
- Sync never marks a recording `failed`, never touches `status`, never
  deletes except through the tombstone rule above. `status` does travel
  verbatim on the wire — a row pushed mid-pipeline can arrive on another
  device as `pendingTranscription`/`transcribing` with no local media yet
  (see Media below) — so the mechanism that keeps this true is on the *receiving*
  end: `RecordingsController._enqueueProcessing`, the funnel behind
  `resumeInterruptedProcessing`, RETRY and every capture path, refuses —
  no status change — when any segment's source file is not on this device.
  See `docs/architecture/capture-pipeline.md`.
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
new-id-adds. `test/cloud_sync_coordinator_test.dart` covers the metadata
slot, the Storage slot's order and message, and a partial success.
`test/sync/media_sync_test.dart` covers `MediaSyncService` against an
in-memory bucket; `test/sync/media_sync_slot_test.dart` covers the slot
through `RecordingsController.syncCloud()` — re-root, download, hand-off,
rejection, upload. pgTAP for `sync_push` and the `captures` bucket lives in
`supabase/tests/`.

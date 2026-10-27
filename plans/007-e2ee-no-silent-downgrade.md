# 007 — E2EE: a row that was sealed never comes back unsealed, and a fresh device never defaults to plaintext silently

| Field | Value |
| --- | --- |
| Status | DONE — Part A merged in #378 (issue #377); Part B decided yes and implemented in #379 |
| Written against | commit `4ab9f54` (branch `main`), 2026-10-23 |
| Finding | security #7 in `plans/README.md` (E2EE downgrade) |
| Effort | Part A: M (one day). Part B: S after the decision (half a day, mostly UI copy). |
| Fix risk | Part A: medium — touches the pull-apply loop and the SQLite `sync_rows` bookkeeping table. Part B: low. |
| Depends on | 006 (merged, deployed 2026-10-23). **Context:** the hosted project gained the E2EE schema only on 2026-10-23, so today every row on the server is a plaintext legacy row. Part A must therefore accept legacy plaintext rows and refuse only a *downgrade*. |

## Why this matters

The threat E2EE exists for is a hostile or compromised server. Two places still trust the server's word about encryption state:

**Gap 1 — envelope stripping.** The transport accepts any row without an envelope as "legacy":

```dart
// lib/features/sync/data/encrypted_sync_transport.dart:211-218
  Future<Map<String, Object?>> _unsealRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    final Object? encPayload = row['encrypted_payload'];
    if (encPayload is! String || !E2eeCipher.isSealed(encPayload)) {
      return row; // Pre-E2EE legacy row or table without encryption
    }
```

Legacy rows are real (all of production, as of today), so the branch has to exist. But nothing remembers that a given row *was* sealed the last time this device saw it. A server can therefore take a sealed row, drop `encrypted_payload`, write plaintext `transcript`/`payload`/`repository_path` columns of its choosing, and the device applies them as a legitimate edit (and, after plans 002/003, at least not as an artifact path or launch flag). The precise invariant that is missing: **sealed → unsealed is a downgrade and is refused per row.**

**Gap 2 — fresh device.** A device with no key in its keyring asks the server whether the account is encrypted:

```dart
// lib/features/sync/data/e2ee_service.dart:154
      final bool? onServer = restored != null ? true : await _readServerKey(userId);
```

```dart
// lib/features/sync/data/e2ee_service.dart:166-176
  Future<bool?> _readServerKey(String userId) async {
    ...
      final E2eePublicParams? params = await settings.read(userId).timeout(keyringTimeout);
      return params != null;
    } catch (_) {
      return null;
    }
```

A lookup *error* already fails closed (`null` → "sync skipped: could not check whether this account is encrypted", `e2ee_service.dart:327-341` and `:282-297`), which is right. A lookup that *succeeds with no row* (`false`) means "plaintext allowed", and the plain transport then pushes this device's rows in clear. A server that hides the row from one device, or an attacker who deleted it (there is no delete grant — but a server operator can), turns that device into a plaintext uploader. The device has nothing local to contradict the answer. **This cannot be fixed by code alone**: a fresh device genuinely does not know. It can only be fixed by not deciding silently.

## Decision needed (Part B) — recommended answer first

On a device with no key and a server answer of "no encryption row", should the first sync in plaintext require an explicit user confirmation?

- **Recommended: yes.** Replace the automatic `keyOnServer == false → plaintext allowed` with a third state, `plaintextUnconfirmed`, that behaves like locked (sync skipped, Queue banner) until the user taps a one-time **SYNC WITHOUT ENCRYPTION** (or sets up a passphrase). The choice is stored per account in the OS keyring next to where the key would be. Cost: one extra tap on a brand-new install of an account that never enabled E2EE. Benefit: a hidden row can no longer flip a device to plaintext without a human seeing the banner.
- Alternative: keep the automatic behaviour and only add a non-blocking warning. Cheaper, and changes nothing about the attack.

Until this is answered, execute **Part A only**.

**Decided 2026-10-26: yes.** Implemented in #379 as `isPlaintextUnconfirmed` plus `E2eeService.confirmPlaintext()`.

## Part A — refuse sealed → unsealed per row

### Target state

1. `SyncRowState` (`lib/features/sync/domain/sync_snapshot.dart:7-12`) gains `final bool sealed;` (default `false`). `SyncBookkeeping.put` gains the same parameter.
2. `sync_rows` SQLite table gains `sealed INTEGER NOT NULL DEFAULT 0`; `SyncRowsStore` (`lib/features/sync/data/sync_rows_store.dart`) reads and writes it. Existing rows default to `false`, which is the truthful legacy state.
3. The transport marks each pulled row it unsealed with a private key, e.g. `row['__sealed'] = true`, right after a successful unseal in `_unsealRow`; a row returned through the legacy branch gets no marker. (Pick a key that cannot collide with a column; strip it before `Recording.fromJson` if the codec would otherwise choke — check `recordingFromRow` ignores unknown keys first; it builds an explicit map, so it does.)
4. In the pull-apply loop (`lib/features/sync/domain/sync_engine.dart`, the block around `:655` that calls `SyncRowCodec.recordingFromRow(row, local: mine)`), **before** decoding: if `state?.sealed == true` and the row carries no `__sealed` marker → refuse the row: do not apply, do not advance `known[id]`, count it in a new `out.downgraded` counter, log one line per run naming the table and count ("refused n rows that arrived unencrypted after being encrypted"). Do the same in the equivalent apply paths for `segments`, `clipboard_items`, `projects` (and `revisions` if it pulls) — grep the engine for every `fromRow(` call.
5. When a row **is** applied, `known[id] = SyncRowState(serverVersion, pushedHash, sealed: wasSealed)` and the bookkeeping write carries it (`:689`, `:802`, `:840` and wherever `pendingBookkeeping` is flushed).
6. On **push**, a row this device sealed records `sealed: true` in bookkeeping (the engine knows whether the transport is encrypting — expose `bool get isEncrypting` on the transport interface if it does not exist; `grep -n "isEncrypting\|hasKey" lib/features/sync` returned nothing at `4ab9f54`, so add it to `SyncTransport`'s wrapper with a `false` default on the plain transport).
7. `CloudSyncReport` / the Queue's sync summary line shows the `downgraded` count when non-zero, in the same place `skipped` is shown.

### Tests (write first, see red)

- `test/sync/sync_engine_pull_test.dart`: seed bookkeeping with `sealed: true` for id `a`; feed a pulled row for `a` with no `__sealed` marker and a changed `transcript`; assert the local row is unchanged, `out.downgraded == 1`, bookkeeping for `a` unchanged. Then the positive case: same row *with* the marker applies normally and keeps `sealed: true`. Then the legacy case: bookkeeping `sealed: false`, unmarked row applies (this is today's behaviour and must keep working for every production row).
- `test/sync/encrypted_sync_transport_test.dart`: an unsealed row passes through without the marker; a sealed row comes back unsealed **with** the marker.
- `test/sync/` bookkeeping test for `SyncRowsStore`: round-trip `sealed`, and a pre-existing row (insert without the column via raw SQL on a fresh db built from the *old* `CREATE TABLE`) reads back `false` — this pins the migration. Look at `lib/core/database/app_database.dart:139` for the `CREATE TABLE IF NOT EXISTS sync_rows` statement and at how other columns were added later (grep `ALTER TABLE` in that file) to follow the same migration pattern.
- Non-vacuity: comment out the refusal and watch the first test fail.

### Conventions

Pure Dart tests with the existing fakes in `test/sync/fake_sync_transport.dart`; degrade-on-load (`sealed` absent → `false`); the engine never deletes or rewrites a refused row; log through the existing `LogSink`; English strings; Conventional Commits with `Refs #<N>`; no attribution; no `dart format` on existing files. Read `docs/architecture/sync.md` sections on the bookkeeping table and the pull apply before editing, and add a paragraph there describing the downgrade rule.

### Scope

In: `sync_snapshot.dart`, `sync_rows_store.dart`, `app_database.dart` (one `ALTER TABLE … ADD COLUMN` following the existing pattern), `encrypted_sync_transport.dart` (marker only), `sync_engine.dart` (refusal + bookkeeping), the report type and its one UI line, tests, `docs/architecture/sync.md`.
Out: `e2ee_service.dart` and anything about the fresh-device decision (Part B); the Supabase schema; media sync.

### Done criteria

```bash
grep -n "sealed" lib/features/sync/domain/sync_snapshot.dart lib/features/sync/data/sync_rows_store.dart | wc -l   # ≥ 6
grep -n "downgraded" lib/features/sync/domain/sync_engine.dart | wc -l                                             # ≥ 3
flutter analyze && flutter test                                                                                     # green
flutter test test/sync/                                                                                             # green, count grew by ≥ 5
```

### Escape hatches — STOP and report if

- The engine applies pulled rows through more than the four codec `fromRow` paths you expected (list them).
- `app_database.dart` has no precedent for adding a column to an existing table (then propose the migration shape before writing it).
- The transport's row map is immutable where you want to set the marker (then return a wrapper record `(row, sealed)` from `_unsealRow` instead and adapt its single caller).
- Adding `isEncrypting` would require changing more than the transport interface and its two implementations.

## Part B — sketch (after the decision)

Introduce `E2eeState.plaintextUnconfirmed` between `keyOnServer == false` and "plaintext allowed" in `e2ee_service.dart` (`_checkPlaintextAllowed`, `_assertStillPlaintext`, and the `restore` future at `:150-160`). Persist the confirmation per `userId` in the same keyring-backed store the key uses, so a reinstall asks again. The Queue banner that today says "NOT ENCRYPTED" gains the confirming action. Tests in `test/sync/e2ee_service_test.dart` already cover the three `_keyOnServer` states; extend them with the fourth.

## Maintenance note

Every new synced table must set `sealed` on push and check it on pull; a table that forgets is a table the server can downgrade. Reviewers: a new `fromRow(` call in the engine without the downgrade check next to it is a regression of Part A.

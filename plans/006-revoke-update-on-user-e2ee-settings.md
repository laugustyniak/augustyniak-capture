# 006 — `user_e2ee_settings` must be insert-once: revoke UPDATE

| Field | Value |
| --- | --- |
| Status | DONE — PR #368 merged `ee1b2c3` 2026-10-23, issue #367; **hosted `supabase db push` not yet run** |
| Written against | commit `c4c82a1` (branch `main`), 2026-10-23 |
| Finding | security #8 in `plans/README.md`: the table grants and allows UPDATE though the client only ever inserts |
| Effort | S (1–2 h; one migration, one pgTAP edit, one doc sentence) |
| Fix risk | low on the schema; **deployment is the risk** — `supabase db push` touches the hosted project and needs the maintainer's explicit go-ahead (CLAUDE.md). The plan stops before it. |
| Depends on | nothing |
| Decision recorded | the E2EE parameters of an account are immutable once set. A future re-key is a new migration with its own policy, not a reopened UPDATE grant. |

## Why this matters

`user_e2ee_settings` holds, per owner, the public half of the zero-knowledge key derivation: `kdf_salt`, `kdf_algorithm`, `kdf_iterations` and `key_check_hash`. Every device derives the account key from the passphrase plus this row; `key_check_hash` is how a second device confirms it derived the right key. The client is explicit that the row is written once:

```dart
// lib/features/sync/data/supabase_e2ee_settings_store.dart:6-7
/// insertable and updatable by its owner only (RLS), with no delete grant.
/// This client only ever inserts: an update would re-key the account and
```

and `grep -n "\.update(" lib/features/sync/data/supabase_e2ee_settings_store.dart` returns nothing. But the schema still allows it:

```sql
-- supabase/migrations/20261006200000_e2ee_encrypted_payload.sql:38-39
revoke all on table public.user_e2ee_settings from public, anon, authenticated;
grant select, insert, update on table public.user_e2ee_settings to authenticated;
```

```sql
-- supabase/migrations/20261006200000_e2ee_encrypted_payload.sql:52-55
create policy user_e2ee_settings_update_own on public.user_e2ee_settings
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create trigger user_e2ee_settings_reject_owner_change
  before update on public.user_e2ee_settings
  for each row execute function public.reject_owner_change();
```

So a stolen or leaked session (the bearer token is the only thing standing between the network and `authenticated`) can issue one PostgREST `PATCH` that rewrites `kdf_salt`, `kdf_iterations` or `key_check_hash`. Every envelope already in the cloud stays sealed under the old key; the device that holds that key keeps working and notices nothing. Every **other** device, and every reinstall, derives a different key from the new salt, fails the check hash, and cannot unlock the account — with no way to tell *why*, because the row looks well-formed. The attack destroys availability of the user's own data with a single request the client never makes.

The `kdf_iterations` range check added later (`20261012090000_e2ee_revisions_payload_kdf_iterations.sql:26-28`) bounds the value but not who may change it.

## Target state

1. A new migration revokes `update` on `public.user_e2ee_settings` from `authenticated`, drops policy `user_e2ee_settings_update_own`, and drops trigger `user_e2ee_settings_reject_owner_change` (it only guarded updates, which no longer exist). `select` and `insert` grants and policies stay exactly as they are.
2. The pgTAP suite proves it: an owner's `update` is refused with `42501` (insufficient privilege), and the catalog shows no update policy on the table. The three existing tests that *use* `update` on this table are rewritten so they still test what they meant to.
3. `docs/architecture/sync.md` and the store's doc comment say the row is insert-once at the database level.
4. **The plan ends at a green local `supabase test db`.** Applying the migration to the hosted project is a separate, maintainer-run step.

## Current state — more facts to verify

The existing tests that update the table, all in `supabase/tests/e2ee_encrypted_payload_test.sql` (`select plan(14);` at line 2):

| Line | What it does today | Why it exists |
| --- | --- | --- |
| 34 | `update … set kdf_iterations = 10` expects `23514` (check violation) | proves the range floor |
| 41 | `update … set kdf_iterations = 20000000` expects `23514` | proves the range ceiling |
| 123 | `update … set owner_id = <A> where owner_id = <B>` (signed in as B) expects the owner-change refusal | proves `reject_owner_change` |

After the migration those three statements fail earlier, with `42501`, so the first two no longer test the range check and the third no longer tests anything meaningful (the trigger is gone). Convert them: the range check is tested on **insert** (insert a row for a third test user with `kdf_iterations = 10`, expect `23514`; same for the ceiling), and the owner-change test becomes "an owner's update is refused outright" expecting `42501`.

Test harness facts: `pg_temp.sign_in(uid)` sets the role to `authenticated` and the JWT claims (lines 8-12). Users A and B are inserted at lines 4-6. Local run: `supabase start`, `supabase db reset` (applies every migration from empty), `supabase test db` (pgTAP). Migration file naming: `YYYYMMDDHHMMSS_snake_case.sql`, ordered by timestamp.

## Conventions to follow

- Migration header comment in the style of the two E2EE migrations: start with the issue reference, say what the change is *for* in two or three sentences, name the invariant it enforces.
- pgTAP tests in the style of the existing file: `throws_ok($$ … $$, '<sqlstate>', null, '<description>')`, `is(…)`, and the `plan(n)` count updated to match.
- Policy and catalog assertions: see `supabase/tests/user_owned_metadata_test.sql:85-93` for the `pg_class`/`pg_policy` style.
- Docs: one sentence in `docs/architecture/sync.md` near line 549 ("one `user_e2ee_settings` row per owner …") and update the store comment at `supabase_e2ee_settings_store.dart:6-7` ("insertable by its owner only (RLS); no update or delete grant").
- Conventional Commits: `fix(supabase): …`, footer `Refs #<N>`. No AI attribution.

## Scope boundaries

In scope: one new file `supabase/migrations/<timestamp>_e2ee_settings_insert_once.sql`; `supabase/tests/e2ee_encrypted_payload_test.sql`; one sentence in `docs/architecture/sync.md`; two lines of doc comment in `supabase_e2ee_settings_store.dart`.

Out of scope — do not touch: any other table's grants; `reject_owner_change()` the function (other tables use it); the client's `create`/`read` logic; `supabase db push`; anything in `lib/` beyond the comment.

## Steps

### Step 0 — Drift check

```bash
git rev-parse --short HEAD
grep -n "grant select, insert, update on table public.user_e2ee_settings" supabase/migrations/*.sql   # 1 hit
grep -rn "user_e2ee_settings" supabase/migrations/ | grep -ci "revoke update"                          # 0 — if 1, this plan is done
grep -n "update public.user_e2ee_settings" supabase/tests/e2ee_encrypted_payload_test.sql | wc -l     # 3
grep -c "\.update(" lib/features/sync/data/supabase_e2ee_settings_store.dart                            # 0 — if not 0, STOP: the client updates after all
```

### Step 1 — Issue, worktree, local Supabase

```bash
gh issue create --title "user_e2ee_settings allows UPDATE though the client only inserts" --label security \
  --body "A session can rewrite kdf_salt / key_check_hash and lock every other device out. Plan: plans/006-revoke-update-on-user-e2ee-settings.md"
git fetch origin
git worktree add .worktrees/fix-<N>-e2ee-settings-insert-once -b fix/<N>-e2ee-settings-insert-once origin/main
cd .worktrees/fix-<N>-e2ee-settings-insert-once
supabase start          # needs Docker; if it fails, STOP and report — the plan cannot be verified without it
supabase db reset       # expected: every migration applied, no error
supabase test db        # expected: all four files pass; note the total
```

### Step 2 — Failing test first

Edit `supabase/tests/e2ee_encrypted_payload_test.sql`:

1. Replace the two `update … kdf_iterations` tests (lines 34 and 41) with **inserts** for a third user you add to the `auth.users` insert at line 4 (e.g. `55555555-5555-5555-5555-555555555555`), signed in as that user, each expecting `23514`. Keep the descriptions.
2. Replace the owner-change update test (line 123) with:
   ```sql
   select throws_ok(
     $$ update public.user_e2ee_settings set kdf_salt = 'rotated' where owner_id = '44444444-4444-4444-4444-444444444444' $$,
     '42501',
     null,
     'an owner cannot update their own e2ee settings — the row is insert-once'
   );
   ```
   (signed in as B, B's own row.)
3. Add a catalog assertion:
   ```sql
   select is(
     (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
       where c.relname = 'user_e2ee_settings' and p.polcmd = 'w'),
     0::bigint,
     'no update policy exists on user_e2ee_settings'
   );
   ```
   (`polcmd = 'w'` is UPDATE.)
4. Bump `plan(14)` to match the new test count.

Run `supabase test db`. Expected: the `42501` test and the catalog test **fail** (today the update succeeds and the policy exists). The two insert-range tests pass already (the check constraint applies on insert too) — that is fine; they keep the coverage the old update tests gave.

### Step 3 — Migration

Create `supabase/migrations/$(date -u +%Y%m%d%H%M%S)_e2ee_settings_insert_once.sql`:

```sql
-- Zero-knowledge E2EE (issue #<N>): the KDF row is insert-once.
--
-- `user_e2ee_settings` holds the public half of the account key derivation.
-- Every device derives the key from the passphrase plus this row, and
-- `key_check_hash` is how a second device knows it derived the right one. The
-- client only ever inserts; an update would re-key the account under every
-- other device and leave the envelopes already in the cloud unreadable to
-- them. A leaked session must not be able to do with one PATCH what the client
-- never does, so UPDATE is withdrawn at the grant, the policy and the trigger
-- that only existed to guard it.

drop trigger if exists user_e2ee_settings_reject_owner_change on public.user_e2ee_settings;
drop policy if exists user_e2ee_settings_update_own on public.user_e2ee_settings;
revoke update on table public.user_e2ee_settings from authenticated;
```

### Step 4 — Verify

```bash
supabase db reset      # applies the new migration from empty — must succeed
supabase test db       # expected: all pass, including the two new assertions
```

Also re-run the full Flutter suite once (`flutter test`) — nothing in `lib/` changed functionally, so it must stay green; this is only to catch a test that greps migration files.

### Step 5 — Docs and commit

- `docs/architecture/sync.md` near line 549: add "The row is insert-once at the database level: `authenticated` has no UPDATE grant and no update policy (migration `…_e2ee_settings_insert_once.sql`); a re-key would be a new migration."
- `supabase_e2ee_settings_store.dart:6-7`: "insertable by its owner only (RLS); there is no update or delete grant, so the row is insert-once."

```
fix(supabase): make user_e2ee_settings insert-once

The client only ever inserts the KDF row, but authenticated still held an
UPDATE grant and an update policy, so a leaked session could rewrite the
salt or the check hash and lock every other device out. UPDATE is
withdrawn at the grant, the policy and the owner-change trigger that only
guarded it; pgTAP now asserts the refusal and the missing policy.

Refs #<N>
```

### Step 6 — Hand over the deployment

**Do not run `supabase db push`.** In the PR description state: "Needs `supabase db push` to the hosted project after merge; maintainer-run." Stop there.

## Done criteria

```bash
ls supabase/migrations | grep -c e2ee_settings_insert_once          # 1
grep -c "42501" supabase/tests/e2ee_encrypted_payload_test.sql       # ≥ 1
grep -c "update public.user_e2ee_settings" supabase/tests/e2ee_encrypted_payload_test.sql   # 1 (the refusal test only)
supabase db reset && supabase test db                                 # all pass
flutter analyze && flutter test                                       # unchanged, green
```

## Maintenance note

Any future need to change an account's KDF parameters is a **re-key**, which means re-encrypting every envelope; it needs its own migration, its own policy with a narrower shape (e.g. a server function that checks a proof of the old key), and a client flow. Reopening the UPDATE grant is never the answer. The `reject_owner_change()` function stays in use by other tables; only this table's trigger went.

## Escape hatches — STOP and report if

- `supabase start` cannot run (no Docker) — the plan cannot be verified locally; say so rather than shipping an untested migration.
- Any client code path updates the table (`grep -rn "user_e2ee_settings" lib` showing an `.update(` or `.upsert(`).
- `supabase db reset` fails on the new migration with anything other than a typo you can see.
- A migration later than `20261012090000` already touches this table's grants.

## Execution record (2026-10-23)

- Executor: `coder` in `.worktrees/fix-367-e2ee-settings-insert-once` from `3e8074ee`; commit `82ca31b`, `Refs #367`. PR #368, CI 4/4.
- Local verification: `supabase db reset && supabase test db` 119 → 120 tests, both new assertions seen red first (`caught: no exception / wanted: 42501`; `have: 1 / want: 0`). Flutter suite 2352 green.
- Migration file: `supabase/migrations/20261023011253_e2ee_settings_insert_once.sql`.
- **Deployment owed:** `supabase db push` to the hosted project (maintainer-run, per CLAUDE.md).

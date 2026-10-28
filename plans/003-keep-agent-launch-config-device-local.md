# 003 — A project's agent launch configuration never arrives from sync or a backup archive

| Field | Value |
| --- | --- |
| Status | DONE — PR #358 merged `a38bc5c` 2026-10-22; branch `fix/353-launch-config-local` @ `747e1c5`, issue #353, advisor-reviewed 2026-10-22 |
| Written against | commit `294976b` (branch `main`), 2026-10-21 |
| Finding | security (remote data controls local process launch flags), high confidence on the path, medium on exploitability |
| Effort | M (half a day) |
| Fix risk | medium — changes what the `projects` sync row carries; must not cause a push/pull ping-pong between devices |
| Depends on | nothing; land after 002 to keep the sync codec diffs sequential |
| Decision recorded | agent launch settings are **device-local**. They stop travelling in the sync payload and are never read from a pulled row or an archive. The maintainer can reverse this later by adding an explicit per-device "trust this project's launch settings" confirmation; that is not this plan. |

## Why this matters

A `Project` owns where an agent is started and how:

```dart
// lib/features/projects/domain/project.dart:30-47 (AgentSettings)
class AgentSettings {
  const AgentSettings({
    this.additionalArgs = const <String>[],
    this.initialPrompt,
    this.skipPermissions = false,
  });
  ...
  /// Start the agent without per-tool approval prompts.
  final bool skipPermissions;
```

The hand-off path passes those straight to the process:

```dart
// lib/features/recordings/data/project_agent_handoff.dart:179-181
          ...settings.additionalArgs,
          if (settings.skipPermissions)
            ...launcherAgent.skipPermissionsArguments,
```

where `skipPermissionsArguments` is e.g. `--dangerously-skip-permissions` (`lib/features/projects/domain/agent_session_launcher.dart:33`). The agent is started in `project.repoPath`, with the user's dictated capture as the prompt.

Projects sync. The whole `Project.toJson()` — including `agentSettings` — travels as the row's `payload`:

```dart
// lib/features/sync/domain/sync_row_codec.dart:274-298
  static Map<String, Object?> project(Project pr) => <String, Object?>{
    'id': pr.id,
    'name': pr.name,
    'repository_path': pr.repoPath,
    'payload': pr.toJson()
      ..remove('id')
      ..remove('name')
      ..remove('repoPath'),
  };

  static Project? projectFromRow(Map<String, Object?> row) {
    ...
    final Map<String, dynamic> json = <String, dynamic>{
      if (payloadRaw is Map) ...Map<String, dynamic>.from(payloadRaw),
      'id': row['id'],
      'name': row['name'],
      'repoPath': row['repository_path'] ?? '',
    };
    try {
      return Project.fromJson(json);
```

and the pulled project replaces the local one unchanged:

```dart
// lib/features/projects/presentation/projects_controller.dart:200-209
  Future<void> applySyncedProjects(List<Project> upserts) async {
    if (upserts.isEmpty) return;
    final Map<String, Project> byId = <String, Project>{
      for (final Project p in _projects) p.id: p,
    };
    for (final Project p in upserts) {
      byId[p.id] = p;
    }
    await _save(byId.values.toList(), activeProjectId: _activeProjectId);
  }
```

A backup archive's `projects.json` is merged the same way for ids not yet known locally (`lib/features/backup/data/zip_capture_archive.dart:731-775`, `Project.fromJson(row)` then `merged.add(incoming)`).

So whoever can write to the user's `projects` table (a stolen Supabase session, or a hostile server — the adversary the E2EE plan is written against) or hand the user a backup zip can plant a project with `skipPermissions: true`, arbitrary `additionalArgs` and an `initialPrompt`. The next "send to agent" on this machine starts Claude/Codex/Gemini with approval prompts off, in a directory the attacker chose, with the attacker's prompt. The user's own capture text is appended. Nothing on this device confirmed any of it.

`repoPath` is a different question: it is a real column "by schema design" (`sync_row_codec.dart:88`), two machines with the same home layout legitimately share it, and the writes it governs are an `inbox.md` append behind `refuseSymlink` (`project_inbox_router.dart:62`) and the agent's working directory. **This plan leaves `repoPath` as it is** and removes only the launch configuration from the trust boundary. Say so in the PR.

## Target state

1. `SyncRowCodec.project()` strips `agentSettings` from the pushed payload. Launch settings never leave the device, so the pushed row's hash no longer changes when the user edits them — this is what prevents a push/pull ping-pong (the engine pushes a row when `SyncRowCodec.hash(row) != pushedHash`, `sync_engine.dart:294-304`).
2. `SyncRowCodec.projectFromRow()` ignores `agentSettings` in a payload even if present (rows pushed by older builds still carry them).
3. `ProjectsController.applySyncedProjects()` keeps the **local** project's `agentSettings` for an id that already exists; a brand-new pulled project gets none.
4. `ZipCaptureArchive._mergeProjects()` imports a project with `agentSettings` cleared.
5. `Project.fromJson` is **unchanged** — `projects.json` on disk is the device-local store and must keep loading settings.
6. Tests pin 1–4; docs say launch settings are per device.

## Current state — more excerpts to verify

```dart
// lib/features/backup/data/zip_capture_archive.dart:763-771
    for (final dynamic row in rows) {
      try {
        final Project incoming = Project.fromJson(row as Map<String, dynamic>);
        if (!isSafeRecordId(incoming.id)) continue;
        if (known.contains(incoming.id)) continue;
        merged.add(incoming);
        known.add(incoming.id);
        changed = true;
```

```dart
// lib/features/projects/domain/project.dart:163-196 — copyWith accepts agentSettings:
  Project copyWith({
    ...
    Map<AgentKind, AgentSettings>? agentSettings,
    ...
```

Note `copyWith(agentSettings: null)` keeps the old value (`agentSettings ?? this.agentSettings`), so to **clear** settings pass `agentSettings: const <AgentKind, AgentSettings>{}`.

Engine use of the codec: `sync_engine.dart:198`:
```dart
      for (final Project p in s.projects) p.id: SyncRowCodec.project(p),
```

## Conventions to follow

- Codec tests: `test/sync/sync_row_codec_test.dart` — "project round-trips through a server row" at `:246` is the exemplar to extend (it will now need to assert that `agentSettings` do **not** round-trip).
- Controller tests: `test/projects_controller_test.dart` (read its `setUp` and fake repository first; reuse them).
- Archive tests: `test/backup_archive_test.dart` — grep `projects.json` there for the existing merge tests.
- Model tests: `test/projects_test.dart:10-30` shows how to build a `Project` with `agentSettings`.
- Pure Dart tests, hand-written fakes. English comments. No `dart format` on existing files. Conventional Commits with `Refs #<N>`; no AI attribution.

## Scope boundaries

In scope:
- `lib/features/sync/domain/sync_row_codec.dart` — `project()` and `projectFromRow()` only.
- `lib/features/projects/presentation/projects_controller.dart` — `applySyncedProjects()` only.
- `lib/features/backup/data/zip_capture_archive.dart` — the `_mergeProjects` loop only.
- Tests for each, plus `docs/architecture/sync.md` and `docs/architecture/agent-handoff.md` (one paragraph: launch settings are device-local and why).

Out of scope — do not touch:
- `Project.fromJson` / `toJson` / `projects.json` format.
- `repoPath` handling, `project_inbox_router.dart`, the launchers, `skipPermissionsArguments`.
- `defaultAgent`, `sessionName`, `commandHost`/`commandWorkspace` (they select *which* agent/host, not *how* it runs; leave them syncing).
- The Supabase schema. No migration is needed: `payload` is JSON.
- The E2EE transport.

## Steps

### Step 0 — Drift check

```bash
git rev-parse --short HEAD
grep -n "'payload': pr.toJson()" lib/features/sync/domain/sync_row_codec.dart          # 1 hit
grep -n "byId\[p.id\] = p;" lib/features/projects/presentation/projects_controller.dart  # 1 hit
grep -n "merged.add(incoming);" lib/features/backup/data/zip_capture_archive.dart        # 1 hit
grep -rn "agentSettings" lib/features/sync lib/features/backup                           # expected: 0 hits today
```

If the last grep already shows hits in those two directories, STOP: someone started this.

### Step 1 — Issue, worktree, baseline

```bash
gh issue create --title "Synced or imported projects carry agent launch flags this device never confirmed" \
  --label security \
  --body "agentSettings (additionalArgs, initialPrompt, skipPermissions) travel in the projects sync payload and in backup archives and are applied unchanged. Plan: plans/003-keep-agent-launch-config-device-local.md"
git fetch origin
git worktree add .worktrees/fix-<N>-launch-config-local -b fix/<N>-launch-config-local origin/main
cd .worktrees/fix-<N>-launch-config-local && flutter pub get
flutter analyze && flutter test
```

### Step 2 — Failing tests

1. `test/sync/sync_row_codec_test.dart`:
   - Extend "project round-trips through a server row": build the project **with** `agentSettings` (copy from `test/projects_test.dart:19-28`), encode with `SyncRowCodec.project`, assert `(row['payload'] as Map).containsKey('agentSettings')` is **false**, decode, assert `back.agentSettings` is empty while `name`, `repoPath`, `defaultAgent`, `sessionName` survive.
   - New test "a pulled project row's agentSettings are ignored even when present": take a row, inject `payload['agentSettings'] = {'claudeCode': {'skipPermissions': true, 'additionalArgs': ['--x']}}`, decode, assert `settingsFor(AgentKind.claudeCode).skipPermissions` is false and `additionalArgs` empty.
   - New test "editing launch settings does not change the project row hash": two projects identical except `agentSettings`; `SyncRowCodec.hash(SyncRowCodec.project(a)) == SyncRowCodec.hash(SyncRowCodec.project(b))`. This is the ping-pong guard.
2. `test/projects_controller_test.dart`: "applySyncedProjects keeps this device's launch settings for a known id and gives a new id none" — seed a local project with settings, apply an upsert for the same id with a new name and different settings, assert name updated and settings equal the local ones; apply an upsert for a new id carrying settings, assert it lands with empty settings.
3. `test/backup_archive_test.dart`: "an archived project is imported without its launch settings" — write a `projects.json` member with `agentSettings` into an archive the way the existing project-merge test does, import, assert the merged project has empty `agentSettings`.

Run the three files; expected: new tests **fail**.

### Step 3 — Codec

```dart
  // sync_row_codec.dart — project()
  static Map<String, Object?> project(Project pr) => <String, Object?>{
    'id': pr.id,
    'name': pr.name,
    'repository_path': pr.repoPath,
    // Launch settings (extra arguments, an initial prompt, the skip-permissions
    // switch) are device-local by decision: a row another device or a hostile
    // server wrote must not decide how an agent is started here. Leaving them
    // out of the payload also keeps the row's hash stable when they are edited,
    // so a local-only change never dirties the outbox.
    'payload': pr.toJson()
      ..remove('id')
      ..remove('name')
      ..remove('repoPath')
      ..remove('agentSettings'),
  };
```

In `projectFromRow`, after building `json`, add `json.remove('agentSettings');` with a one-line comment: rows pushed by older builds still carry them.

### Step 4 — Controller

In `applySyncedProjects`:

```dart
    for (final Project p in upserts) {
      final Project? mine = byId[p.id];
      // Launch settings never travel (SyncRowCodec.project); a pulled row has
      // none, so an existing project keeps this device's own.
      byId[p.id] = mine == null ? p : p.copyWith(agentSettings: mine.agentSettings);
    }
```

Check `copyWith` keeps `commandHost`/`commandWorkspace` from `p` (it does, they default to `this.` values) — the pulled row wins for everything except launch settings.

### Step 5 — Archive

In `_mergeProjects`, replace `merged.add(incoming);` with

```dart
        // Launch settings are device-local (see SyncRowCodec.project); an
        // archive made elsewhere must not decide how an agent is started here.
        merged.add(incoming.copyWith(agentSettings: const <AgentKind, AgentSettings>{}));
```

Add the import for `AgentKind`/`AgentSettings` if `project.dart` is not already imported there (it is, for `Project`; both types live in the same file).

### Step 6 — Docs

- `docs/architecture/sync.md`: in the projects / path-policy section, one paragraph: what travels (`name`, `repository_path`, description, session name, default agent, Command binding) and what does not (`agentSettings`), and the two reasons (trust boundary; hash stability).
- `docs/architecture/agent-handoff.md`: one sentence where `AgentSettings` is introduced: they are per device and are never taken from sync or a backup.

### Step 7 — Gates, commit

```bash
flutter analyze && flutter test
```

```
fix(sync): keep agent launch settings device-local

additionalArgs, initialPrompt and skipPermissions no longer travel in the
projects payload, are ignored when a pulled row carries them, survive a
pull for a project this device already has, and are cleared on archive
import. A remote writer can no longer decide how an agent is started
here, and editing them no longer dirties the outbox.

Refs #<N>
```

## Done criteria

```bash
grep -n "remove('agentSettings')" lib/features/sync/domain/sync_row_codec.dart            # ≥ 1
grep -n "agentSettings: mine.agentSettings" lib/features/projects/presentation/projects_controller.dart   # 1
grep -n "agentSettings: const <AgentKind, AgentSettings>{}" lib/features/backup/data/zip_capture_archive.dart   # 1
flutter analyze    # No issues found!
flutter test       # All tests passed!
flutter test --plain-name "launch settings"   # ≥ 3 tests pass
flutter test test/sync/   # all pass (push and pull engine tests unaffected)
```

## Maintenance note

Anything added to `AgentSettings` is automatically device-local now (the whole key is stripped). Anything added to `Project` **outside** `AgentSettings` travels by default — reviewers should ask, for every new `Project` field, "can a remote writer hurt this device with it?" The companion rule for file paths is plan 002. If the maintainer later wants cross-device launch settings, the right shape is a per-device confirmation step in the Projects tab, not re-adding the key to the payload.

## Escape hatches — STOP and report if

- `test/sync/sync_engine_push_test.dart` or `sync_engine_pull_test.dart` fail after Step 3 for a reason other than an expected-row fixture that includes `agentSettings` (update such fixtures; report anything else).
- `applySyncedProjects` is also used by the backup restore path or by `_mergeProjects` (grep its callers) — then Step 5 may be redundant or conflict; report before editing both.
- `Project.copyWith` does not expose `agentSettings` in your checkout.
- You find a second code path that constructs a `Project` from remote data (grep `Project.fromJson(` in `lib/features/sync`, `lib/features/backup`, `lib/features/command`).

## Execution record (2026-10-22)

- Executor: `coder` in `.worktrees/fix-353-launch-config-local` from `00dcc3e`; one commit `747e1c5`, `Refs #353`, no attribution. PR #358.
- Drift: none beyond plan 002 having landed in the same codec file.
- **Plan bug found by the executor:** Step 4's suggested code `mine == null ? p : p.copyWith(...)` let a brand-new pulled project keep remote settings, contradicting the target state. Shipped as `p.copyWith(agentSettings: mine?.agentSettings ?? const {})`. The done-criteria grep for the literal `agentSettings: mine.agentSettings` therefore does not match; the behaviour is the one the plan asked for and the test pins it.
- Tests: five new, each quoted red before the fix (payload key present; `skipPermissions` read; hash differs; remote settings replaced local; archive carried settings). Suite 2315 → 2319.
- Advisor review: every `lib/` hunk traces to Steps 3–5; `repoPath` still syncs as decided; hash stability confirmed by the encoder strip. Gates re-run: analyze clean, 2319 passed / 4 skipped, `test/sync/` 222.

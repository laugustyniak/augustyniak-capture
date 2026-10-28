# 002 — Agent artifact paths must not arrive from a synced row or a backup archive

| Field | Value |
| --- | --- |
| Status | IMPLEMENTED — branch `fix/351-artifact-paths` @ `a150bfa` in `.worktrees/fix-351-artifact-paths`, issue #351, advisor-reviewed 2026-10-22, PR #352 merged 2026-10-22 |
| Written against | commit `294976b` (branch `main`), 2026-10-21 |
| Finding | security (file disclosure via pulled/imported data), high confidence |
| Effort | S (2–4 h) |
| Fix risk | low — the policy class already states this rule; the two codecs just never applied it |
| Depends on | nothing |
| Related | 003 (same theme: pulled and imported data must not carry local paths or launch configuration) |

## Why this matters

A `Recording` carries `artifacts`: a list of `AgentArtifact` with an absolute `path` to a file an agent produced on **the machine that ran the agent** (`lib/features/recordings/domain/agent_artifact.dart:19-40`). The app acts on those paths:

```dart
// lib/features/recordings/presentation/agent_artifact_viewer_modal.dart:60-70
  Future<void> _loadFileContent() async {
    try {
      final File file = File(widget.artifact.path);
      if (!await file.exists()) { ... return; }
      final String text = await file.readAsString();
```

```dart
// agent_artifact_viewer_modal.dart:92-98
  Future<void> _openExternal() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('open', <String>[widget.artifact.path]);
      }
    } catch (_) {}
  }

  Future<void> _promoteToNote() async {
    if (_content == null || _content!.trim().isEmpty) return;
    await widget.controller.addTextNote(_content!);
```

So an artifact path is read, shown, and on one tap ("promote") becomes a new capture — which is then sent to the enrichment model and synced to the cloud.

The repo already decided that such paths **must not travel**. `lib/core/sync/sync_path_policy.dart` says so in its own words:

```dart
// lib/core/sync/sync_path_policy.dart:84-88
    // Artifacts name files in a project repository *on the machine that ran the
    // agent*, and `AgentArtifactViewerModal` passes one to `open`. Nothing here
    // can re-root them into something meaningful, so they do not travel.
    clean['artifacts'] = const <Map<String, dynamic>>[];
```

But `SyncPathPolicy.sanitizePayload` has **no caller** in `lib/` (`grep -rn sanitizePayload lib` finds only its definition and one comment). The codec that actually builds a pulled recording passes artifacts straight through:

```dart
// lib/features/sync/domain/sync_row_codec.dart:212
      'artifacts': payload['artifacts'] ?? <Object?>[],
```

and the backup importer keeps them too:

```dart
// lib/features/backup/data/zip_capture_archive.dart:705
      artifacts: recording.artifacts,
```

Consequence: anyone who can write a row to the user's `recordings` table (a stolen Supabase session; a hostile server, which is the adversary the E2EE plan exists for) or hand the user a backup zip can make a capture whose artifact "result note" is `~/.ssh/id_ed25519`, `.env`, or any readable file. The viewer displays it; PROMOTE exfiltrates it to the LLM provider and the cloud. The codec's own comment at `sync_row_codec.dart:80-90` says these paths "are not a secret" when they *leave* — true, but it does not address what happens when they *arrive*, which is the defect here.

Same-machine round trips are not harmed by the fix: `AgentArtifactScanner` rediscovers artifacts from `.agent-tasks/` on disk (`lib/features/recordings/data/agent_artifact_scanner.dart:85-110`), and a device's own artifacts are preserved on pull by taking them from the **local** row instead of the remote one.

## Target state

1. `SyncRowCodec.recordingFromRow` never takes `artifacts` from the remote payload. It keeps the local row's artifacts when a local row exists, otherwise an empty list.
2. `ZipCaptureArchive._relocate` never carries archived artifacts into the imported row (empty list).
3. `SyncPathPolicy.sanitizePayload` is either used or deleted. **Delete it** (and its tests, if any test imports it — `test/sync_path_policy_test.dart` tests `localFileName` only; check with `grep -n sanitizePayload test/sync_path_policy_test.dart`). Dead security code that promises something nobody enforces is worse than no code. Keep `localFileName`, which is used.
4. Tests pin both boundaries.

Optional, **out of scope here** (note it in the PR as follow-up): the viewer's `_openExternal` calls `open` on Linux, where the opener is `xdg-open` (see `lib/features/recordings/data/system_media_opener.dart:19-24`). Unrelated bug; do not fix in this PR.

## Current state — exact excerpts (verify before editing)

```dart
// lib/features/sync/domain/sync_row_codec.dart:158-166
  static Recording? recordingFromRow(
    Map<String, Object?> row, {
    Recording? local,
  }) {
    if (_stillSealed(row)) return null;
    final Object? id = row['id'];
    final DateTime? createdAt = _date(row['created_at']);
    if (id is! String || createdAt == null) return null;
```

```dart
// lib/features/sync/domain/sync_row_codec.dart:210-216
      'instruction': payload['instruction'],
      'routes': payload['routes'] ?? <Object?>[],
      'artifacts': payload['artifacts'] ?? <Object?>[],
      if (payload.containsKey('segments'))
        'segments': _restoreSegmentPaths(payload['segments'], localSegmentPaths)
      else if (local != null && local.hasStoredSegments)
        'segments': local.toJson()['segments'],
```

```dart
// lib/features/backup/data/zip_capture_archive.dart:674-676, 703-705
  Recording _relocate(Recording recording, Directory directory) {
    return Recording(
      id: recording.id,
      ...
      routes: recording.routes,
      artifacts: recording.artifacts,
```

Caller of the codec: `lib/features/sync/domain/sync_engine.dart:655`:
```dart
      final Recording? theirs = SyncRowCodec.recordingFromRow(row, local: mine);
```

How the local row's artifacts serialise: `Recording.toJson()['artifacts']` is a `List<Map<String, dynamic>>` of `AgentArtifact.toJson()`. Check `lib/features/recordings/domain/recording.dart` for the exact key (`grep -n "'artifacts'" lib/features/recordings/domain/recording.dart`).

## Conventions to follow

- Codec tests live in `test/sync/sync_row_codec_test.dart`. Exemplar of the style — a pulled row must not choose a location:

```dart
// test/sync/sync_row_codec_test.dart:114 (title) — read the whole test as the pattern
  test('a pulled row never chooses a location on this device', () {
```

- Backup tests live in `test/backup_archive_test.dart` (one big file; find `_relocate`-adjacent behaviour by grepping `routes` or `thumbPath: null` there and copy the nearest round-trip test).
- Pure Dart tests, hand-written fakes, no mocks. Degrade-on-load rule: a missing or malformed `artifacts` key must never throw.
- Comments in English; match the file's voice (explanatory, says *why*).
- No `dart format` on existing files.
- Conventional Commits with `Refs #<N>`; no AI attribution.

## Scope boundaries

In scope:
- `lib/features/sync/domain/sync_row_codec.dart` (one line + comment at `:212`; update the comment block at `:80-90` to say artifacts are dropped on arrival).
- `lib/features/backup/data/zip_capture_archive.dart` (one line at `:705` + comment).
- `lib/core/sync/sync_path_policy.dart` (delete `sanitizePayload` and its doc block; keep `localFileName` and the class doc).
- `test/sync/sync_row_codec_test.dart`, `test/backup_archive_test.dart`, `test/sync_path_policy_test.dart` (only if it references `sanitizePayload`).
- `docs/architecture/sync.md` and `docs/architecture/backup.md`: one sentence each stating that `artifacts` never arrive from a remote row or an archive.

Out of scope — do not touch:
- `agent_artifact_viewer_modal.dart`, `agent_artifact_scanner.dart`, `agent_artifact.dart`.
- `routes[].target` (a string shown in the HISTORY section; grep found no code opening it). Mention in the PR that it was checked.
- The `project` / `repository_path` handling (plan 003).
- The E2EE transport.

## Steps

### Step 0 — Drift check

```bash
git rev-parse --short HEAD
grep -rn "sanitizePayload" lib test        # expected: lib/core/sync/sync_path_policy.dart definition + comment in sync_row_codec.dart; maybe tests
grep -n "'artifacts': payload\['artifacts'\]" lib/features/sync/domain/sync_row_codec.dart   # expected: 1 hit
grep -n "artifacts: recording.artifacts" lib/features/backup/data/zip_capture_archive.dart    # expected: 1 hit
```

If either grep returns 0 hits, STOP: the fix may already be in.

### Step 1 — Issue, worktree, baseline

```bash
gh issue create --title "Pulled and imported rows carry agent artifact paths the viewer reads" \
  --label security \
  --body "SyncPathPolicy.sanitizePayload says artifacts do not travel but has no caller; recordingFromRow and ZipCaptureArchive._relocate pass them through. Plan: plans/002-drop-remote-artifact-paths-at-sync-and-import-boundary.md"
git fetch origin
git worktree add .worktrees/fix-<N>-artifact-paths -b fix/<N>-artifact-paths origin/main
cd .worktrees/fix-<N>-artifact-paths && flutter pub get
flutter analyze && flutter test     # both green before you start
```

The repo is public. The issue body above describes the class of problem without an exploit path; keep it that way.

### Step 2 — Failing tests first

In `test/sync/sync_row_codec_test.dart`, next to "a pulled row never chooses a location on this device", add:

```dart
  test('a pulled row never contributes artifact paths — local ones are kept', () {
    final Recording mine = /* build a Recording with one AgentArtifact whose path is '/home/me/repo/.agent-tasks/x-result.md' — copy how existing tests in this file build a Recording */;
    final Map<String, Object?> row = SyncRowCodec.recording(mine);
    final Map<String, Object?> payload = Map<String, Object?>.from(row['payload'] as Map);
    payload['artifacts'] = <Object?>[
      <String, Object?>{
        'id': 'evil', 'captureId': mine.id, 'title': 'id_ed25519',
        'path': '/home/me/.ssh/id_ed25519',
        'updatedAt': '2026-10-21T00:00:00Z', 'kind': 'resultNote',
      },
    ];

    final Recording? withLocal = SyncRowCodec.recordingFromRow({...row, 'payload': payload}, local: mine);
    expect(withLocal!.artifacts.map((a) => a.path), mine.artifacts.map((a) => a.path));

    final Recording? fresh = SyncRowCodec.recordingFromRow({...row, 'payload': payload});
    expect(fresh!.artifacts, isEmpty);
  });

  test('a payload with malformed artifacts still decodes', () {
    // artifacts: 'not a list' and artifacts: null must not throw
  });
```

Look at how `SyncRowCodec.recording(...)` is named in this file (the encoder; around line 44-62) and reuse it. If building a `Recording` with artifacts needs a constructor parameter you cannot find, grep `artifacts:` in `test/` for an existing example.

In `test/backup_archive_test.dart`, add a test that exports a recording carrying one artifact, imports the archive into a fresh directory, and asserts the imported row's `artifacts` is empty. Copy the nearest export→import round-trip test in that file (grep `routes` or `re-importing the same archive` for the shape).

Run:
```bash
flutter test test/sync/sync_row_codec_test.dart test/backup_archive_test.dart
```
Expected: the new tests **fail** (artifacts come through). If they pass, the test is wrong.

### Step 3 — Codec

In `sync_row_codec.dart` replace line `:212` with:

```dart
      // Artifacts name files on the machine that ran the agent, and the viewer
      // reads and opens whatever path one carries. A remote row therefore never
      // contributes any: this device's own list is kept, a fresh row gets none,
      // and `AgentArtifactScanner` rediscovers them from `.agent-tasks/` here.
      'artifacts': local?.toJson()['artifacts'] ?? <Object?>[],
```

Update the comment block at `:80-90` (encoder side): keep the sentence that paths leave as written, and add that on arrival `artifacts` are dropped (and that `routes[].target` is display-only).

### Step 4 — Archive

In `zip_capture_archive.dart:705` replace with:

```dart
      // Artifact paths belong to the machine that produced the archive; the
      // viewer reads whatever they name, so an archive never supplies them.
      artifacts: const <AgentArtifact>[],
```

Add the import of `agent_artifact.dart` if the file does not already have it (check the existing imports; the `Recording` constructor may already type the list so `const []` works without the import — prefer whatever analyzes clean with the smallest change).

### Step 5 — Delete the dead policy method

In `lib/core/sync/sync_path_policy.dart` remove `sanitizePayload` and its doc block (lines 38-91). Keep `localFileName`. Fix the now-dangling reference in the comment at `sync_row_codec.dart:240` ("as `SyncPathPolicy.sanitizePayload` does" → "like an artifact or a poster with no usable name"). Also remove the `import 'package:path/path.dart' as p;` from the policy file if `localFileName` no longer needs it (analyzer will tell you: unused import).

### Step 6 — Docs

- `docs/architecture/sync.md`: one sentence in the section that describes `SyncPathPolicy` / what a pulled row may say about the filesystem: artifacts never arrive; the local list is kept.
- `docs/architecture/backup.md`: one sentence next to where `thumbPath` is described as excluded: artifacts are dropped on import for the same reason.

### Step 7 — Gates and commit

```bash
flutter analyze && flutter test
```

```
fix(sync): drop remote artifact paths on pull and on archive import

A pulled row or an archived row could name any readable local file as an
agent artifact; the viewer reads it and PROMOTE turns it into a capture.
The codec keeps this device's own artifacts and takes none from the
remote; the archive importer carries none. The unused sanitizePayload,
which already stated the rule, is removed.

Refs #<N>
```

## Done criteria

```bash
grep -rn "sanitizePayload" lib test                           # 0 hits
grep -n "payload\['artifacts'\]" lib/features/sync/domain/sync_row_codec.dart   # 0 hits
grep -n "artifacts: recording.artifacts" lib/features/backup/data/zip_capture_archive.dart   # 0 hits
flutter analyze                                              # No issues found!
flutter test                                                 # All tests passed!
flutter test --plain-name "artifact"                         # ≥ 3 tests, all pass
```

## Maintenance note

Any new field on `Recording` that holds a filesystem path must be listed in `docs/architecture/sync.md`'s path policy and handled in both `recordingFromRow` and `_relocate`. Reviewers: when a PR adds a `path`-like string to `recording.dart`, ask where it is dropped or re-rooted on arrival. The scanner remains the only legitimate producer of artifacts on a device.

## Escape hatches — STOP and report if

- `Recording.artifacts` is non-final or has a setter somewhere that sync uses after decode (grep `artifacts =`); the fix point would then be wrong.
- The sync engine compares `theirs` to `mine` by hash to decide a conflict and the artifact difference now causes every pull to look like a change (watch `test/sync/sync_engine_pull_test.dart`; if it starts failing, report the failing test name rather than patching the engine).
- `test/backup_archive_test.dart` has no export→import round trip you can copy in under ~40 lines.

## Execution record (2026-10-22)

- Executor: `coder` in `.worktrees/fix-351-artifact-paths` from `d55330c`; one commit `a150bfa`, `Refs #351`, no attribution.
- Drift: `_relocate`'s `artifacts:` line moved 705→707, code identical. `sanitizePayload` had 7 tests in `test/sync_path_policy_test.dart`; removed with the method.
- Tests: new codec test seen red (`Actual: ['/home/me/.ssh/id_ed25519']`). `test/backup_archive_test.dart` already had "an agent artifact survives a round trip" (duplicated twice, pre-existing) asserting the opposite; both inverted, both seen red (`Actual: [Instance of 'AgentArtifact']`). Suite count 2320 → 2315 (7 deleted, 2 added).
- Advisor review: `lib/` hunks are the codec line, the archive line, the dead method, three comments. Ping-pong escape hatch checked: `sync_engine.dart:686` hashes the row as applied locally, so a device keeping its own artifacts is not re-dirtied and `_overwritten` sees no artifact diff. Done criteria re-run: three greps 0, `flutter analyze` clean, `flutter test` 2315 / 4 skipped, `test/sync/` 220 pass.
- Noted, out of scope: the duplicated backup test pair; `_openExternal` calls `open` on Linux (should be `xdg-open`).

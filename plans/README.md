# Advisor plans — index

Audit run: 2026-10-21 against commit `294976b` (`main`). Effort level: standard (four parallel read-only auditors, all nine categories, hotspot-weighted). Every finding below was re-opened and confirmed by the advisor before it entered this table; subagent claims that did not survive are under "Considered and rejected".

**Selection default.** The session ran non-interactively, so plans were written for the top five findings by leverage (impact ÷ effort, weighted by confidence). Everything else is listed under "Vetted findings without a plan" and can be turned into a plan on request.

Verification baseline at `294976b`: `flutter analyze` → `No issues found!`; `flutter test` → 2300 passed, 4 skipped, ~35 s. Both gates must stay green after every plan. Flutter on this host is `/snap/bin/flutter`.

## Execution order and dependencies

| Order | Plan | Status | Depends on | Effort | Why this position |
| --- | --- | --- | --- | --- | --- |
| 1 | [001 — Guard capture entry points before the index has loaded](001-guard-capture-entry-points-before-load.md) | DONE (PR #350 merged `d55330c`) | — | S | Smallest diff, protects durability invariant 2 from an unrecoverable loss. Touches `recordings_controller.dart`; land before 004. |
| 2 | [002 — Drop remote artifact paths at the sync and import boundary](002-drop-remote-artifact-paths-at-sync-and-import-boundary.md) | DONE (PR #352 merged) | — | S | File disclosure via pulled/imported rows. Edits `sync_row_codec.dart`; land before 003. |
| 3 | [003 — Keep agent launch configuration device-local](003-keep-agent-launch-config-device-local.md) | DONE (PR #358 merged `a38bc5c`) | 002 (same codec file; sequential diffs) | M | Remote data must not set `--dangerously-skip-permissions`. Records a product decision; reversible. |
| 4 | [004 — Processing ticker into a ValueNotifier](004-processing-ticker-value-notifier.md) | DONE (PR #359 merged `89afe9c`; manual screen check still owed) | 001 (same controller file) | M | Whole-shell rebuild at 2 Hz for the length of every job. Pattern already exists in the class. |
| 5 | [005 — Docs drift: features, CI, tabs, Turso, on-device status](005-docs-drift-features-ci-tabs.md) | DONE (PR #361 merged) | none; do last so counts do not re-drift | S–M | Agent-facing docs are the repo's control surface; eight verified stale claims. |
| 6 | [006 — `user_e2ee_settings` insert-once: revoke UPDATE](006-revoke-update-on-user-e2ee-settings.md) | DONE (PR #368 merged `ee1b2c3`; hosted `supabase db push` still owed) | none; needs local Supabase (Docker) to verify; `supabase db push` is maintainer-run | S | A leaked session can re-key the account and lock every other device out with one PATCH the client never makes. |

Status values the executor should use: `TODO` → `IN PROGRESS (<branch>)` → `DONE (<PR>)` or `BLOCKED (<reason>)` or `STALE (<why>)`.

Dependency graph:

```
001 ──► 004
002 ──► 003
005 (independent; last)
```

## Vetted findings table (all categories, ordered by leverage)

| # | Finding | Category | Impact | Effort | Fix risk | Conf. | Evidence | Plan |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `startRecording`, `addUpload`, `addImportedFile` and the cloud-sync gate run before `initialize()` finished; `addTextNote`/`addAudioFile` already refuse | correctness | one-row index overwrites whole history; rare, unrecoverable | S | low | med-high | `recordings_controller.dart:1760, 2569, 2634, 1315-1324` vs guards at `:2403, :2512` | 001 |
| 2 | Pulled rows and archives carry `artifacts[].path`; viewer reads/opens it and PROMOTE makes it a capture; `SyncPathPolicy.sanitizePayload` (which drops them) has no caller | security | local file disclosure to LLM + cloud by anyone who can write the user's rows or hand them a zip | S | low | high | `sync_row_codec.dart:212`, `zip_capture_archive.dart:705`, `sync_path_policy.dart:45` (dead), `agent_artifact_viewer_modal.dart:62-101` | 002 |
| 3 | Synced/imported `Project` carries `agentSettings` (`additionalArgs`, `initialPrompt`, `skipPermissions`) applied unchanged; launcher passes them to the agent process | security | remote writer starts an agent here with approvals off, in its directory, with its prompt | M | medium | high (path) / med (exploitability) | `sync_row_codec.dart:274-298`, `projects_controller.dart:200-209`, `zip_capture_archive.dart:763-771`, `project_agent_handoff.dart:179-181` | 003 |
| 4 | 500 ms `Timer.periodic` → `notifyListeners()` during processing rebuilds the shell and re-filters the queue | performance | 2 Hz full rebuild for minutes per job; scales with library size and search | M | low | high (mechanism; not profiled) | `recordings_controller.dart:3942-3949`, `recordings_page.dart:603, 1176`, `queue_tab.dart:432, 466-481, 940-967` | 004 |
| 5 | Agent-facing docs stale: 18 vs 20 features, CI "parked", 7 vs 8 tabs, Turso, on-device "proposed", ISSUES.md "no remote", README test count, `AGENTS.md` lags `CLAUDE.md` | docs | agents follow wrong indices and plan shipped work again | S–M | none | high | `CLAUDE.md:90,149`; `README.md:1196,1200-1203`; `.githooks/pre-push:4-5`; `ui.md:5,7-14,38,43`; `persistence.md:28`; `ISSUES.md:3,7-12`; `docs/plans/2026-08-16-…:3` | 005 |
| 6 | Upload ordering test asserts only `sourcePresentAtSave`, not `statusAtSave`; and no test in that file calls `initialize()` (passes only because of finding 1) | tests | invariant 1 for uploads is under-pinned | S | low | high | `test/upload_controller_test.dart:261-283` vs `test/add_audio_file_test.dart:102` | folded into 001 (Step 6) |
| 7 | E2EE downgrade: unsealed rows are accepted while a key is held; a device with no key treats a missing settings row as "plaintext account" | security | hostile server can strip envelopes / inject plaintext columns; second device uploads plaintext | M | medium | medium | `encrypted_sync_transport.dart:216-217`; `e2ee_service.dart` (`_readServerKey`, `wrapTransport`) | — needs a product decision on the legacy-row migration window |
| 8 | `user_e2ee_settings` grants and allows UPDATE though the client only inserts | security | stolen session can re-key salt/check hash → other devices cannot unlock | S | low | high | `supabase/migrations/20261006200000_e2ee_encrypted_payload.sql:39,52`; `supabase_e2ee_settings_store.dart:6-7` | 006 |
| 9 | Media sync does one serial remote `exists` per segment of the whole library on every run (launch, SYNC NOW, 2 s after each edit) | performance | O(N) round trips per run; ~100 s at 1 000 segments | M | medium | high (count) | `media_sync.dart:216-218, 264-265`; `recordings_controller.dart:1417` | — |
| 10 | Atomic write (`.tmp` + `rename`) copy-pasted in 10 files; symlink guard (#310) applied at 3 sites, none of them the user-data writers | tech-debt | next hardening is 10 edits; inconsistent `restrictToOwner`/error handling | S–M | low | high | `grep -rl "rename(" lib \| xargs grep -l "\.tmp"` → 10 files; `core/security/symlink_guard.dart` callers | — |
| 11 | `RecordingsController` (5 091 lines, 108 commits since Aug) inlines cloud-sync wiring (~300 lines), hash/poster backfill (~250), embeddings (~200) | tech-debt | merge conflicts, review cost | M | low-med | high | `recordings_controller.dart:1155-1457, 1509-1760, 829-1030` | — propose `CloudSyncRunner` first |
| 12 | `recordings_page.dart` is the composition root: ~60 `data/` imports from 15 features inside a 1 725-line `State` | tech-debt | wiring untestable without pumping the page | M | medium | high | `recordings_page.dart:18-89, 295, 751` | — |
| 13 | Layer inversions: `core/database/app_database.dart:10-11` imports feature data; `settings/domain/provider_profile.dart:3-9` imports three features' `data/` | tech-debt | cycles one import away | M | low-med | high | as cited | — |
| 14 | No Linux build job in CI though Linux is the dev host; `ci.yml:11-15` already prescribes the apt packages | dx | Linux-only break (GTK, keybinder, `record_linux` fork) reaches `main` unseen | M | medium | high | `.github/workflows/ci.yml:99-126` | — |
| 15 | CI toolchain unpinned (`channel: stable`, no `flutter-version`, no `setup-java` though docs pin JDK 21) | dx | runner default change breaks CI with no repo change | S | low | high | `ci.yml:109,136`; `docs/platform-setup.md:19-28` | — |
| 16 | Native whisper + ffmpeg tests skip silently on the Linux gate and in `pre-push` | tests | engine regressions report green locally | S | low | medium | `test/whisper_engine_native_test.dart:25`; `test/audio_decoder_test.dart:160` | — |
| 17 | Fixed sleeps in tests the repo forbids (`Future.delayed` 1–800 ms) | tests | known flake class | S | low-med | medium | `test/elapsed_ticker_test.dart:77`; `deletion_test.dart:120`; `suggested_route_test.dart:405,704`; `clipboard_history_test.dart:776` | — |
| 18 | Drain-loop / `_persistAll` error paths under disk-full: a waiter rethrows another caller's failure; `_update` rollback restores a snapshot that discards concurrent mutations | correctness | rows vanish / jobs stall only when persist fails under concurrency | M | medium | medium (read, not reproduced) | `recordings_controller.dart:3915-3930, 4931-4960, 5005-5028` | — |
| 19 | No crash-loop guard: `resumeInterruptedProcessing` re-enqueues every stuck row every launch with no attempt counter | correctness | a poison-pill capture can make the app unusable on launch | M | medium | low-med | `recordings_controller.dart:3804-3820` | — |
| 20 | Whole-file buffers: E2EE media `upload/download`, S3 `upload`, whisper FFI input (3 copies) | performance | OOM on multi-GB video / long audio, mostly mobile | M | medium | medium | `encrypted_media_store.dart`, `s3_media_store.dart`, `whisper_ffi_engine.dart` | — |
| 21 | Storage bucket has no `file_size_limit` / `allowed_mime_types` and no delete policy | security | quota fill from a stolen session; tombstoned media persists | S | low | high (facts) / low (severity) | `supabase/migrations/20260923090000_capture_media_bucket.sql:13-24` | — |
| 22 | RLS catalog test hard-codes 7 table names; a new table passes silently | tests | RLS regression undetected | S | low | high | `supabase/tests/user_owned_metadata_test.sql:85-93` | — |
| 23 | Windows opener `cmd /c start "" <path>`; synced/imported file names are only basenamed, extension not allow-listed | security | metacharacter / `.bat` execution on Open; needs Windows + account compromise | S | low | low-med | `system_media_opener.dart:27-30`; `sync_path_policy.dart:25-36` | — |
| 24 | In-range dependency bumps available: `archive` 4.5.2, `record` 7.1.2, `sqlite3` 3.5.2, `supabase_flutter` 2.18.3, `url_launcher` 6.3.3 (from `flutter pub outdated`) | dependencies | none today | S | low | high | `pubspec.lock` | — (one "bump in-range" commit) |
| 25 | `record_linux` fork pin (`7328fdb`) says "until llfbandit/record#626 ships" — upstream status unverified | dependencies | drop regresses #168 if upstream has not shipped | S check | medium | low on upstream | `pubspec.yaml:47-56`; `test/record_linux_override_test.dart` | — manual check |
| 26 | `integration_test/whisper_android_test.dart` runs nowhere automatically | tests | Android MediaCodec/whisper path never gated | M | medium | high | `docs/architecture/transcription.md:77-82` | — |
| 27 | Large presentation files with no direct test: `work_dashboard_tab.dart` (454), `vault_section.dart` (424), `byoc_storage_section.dart` (400) | tests | changes unseen | M | low | medium (import grep, not coverage) | as named | — |

## Direction findings (options, not ranked against bugs)

- **D-1 One destination seam before more destinations.** Four open plan-backed issues (#244 send-to-any-assistant, #254 trackers, #255 email/Discord, #256 voice-to-running-agent) each describe "a capture leaves the desk". Two seams already exist: `AgentHandoff` (`recordings/domain/agent_handoff.dart:97`) and sealed `SendTarget`/`CaptureSender` (`recordings/domain/capture_sender.dart:9-73`, landed for #244's spike). Building trackers on top of both duplicates delivery logic. Trade-off: unifying touches the hot, tested hand-off path; the Command-intake plan (`docs/plans/2026-08-06-command-intake-integration.md`, still "proposed") changes who launches the agent and should be settled first. Effort M.
- **D-2 Account binding (#206) is the unplanned gap in front of sync and E2EE.** Per-owner RLS and keys exist; nothing binds a pre-existing local library to an account (no `bindAccount` symbol; no plan doc names #206). Ownership of pre-existing captures is hard to reverse once pushed. Effort M; needs the maintainer's ownership rule before code.
- **D-3 On-device transcription is shipped but documented as proposed** (plan 005 fixes the docs). The remaining slices (model download UX, size) need a status pass before anyone re-plans them. Effort S (docs) / M (slices).
- **D-4 One tracker.** `ISSUES.md` says "move to `gh issue` once a remote exists"; `ux-debt.yaml` (12 scored entries) duplicates issue state. Moving the open UX-debt items to labelled GitHub issues and retiring `ISSUES.md` ends the drift; the scoring fields are lost unless encoded as labels. Effort S.

Open issues already covered by a plan doc (do not double-plan): #187, #244, #245, #254, #255, #256, #268; partly #330. Not covered by any plan: #164, #206, #230, #250–#253, #291, #294, #295, #330, #338, #343.

## Considered and rejected (so the next run does not re-audit them)

| Claim | Why rejected |
| --- | --- |
| Clipboard watcher throws `MissingPluginException` twice per tick on Linux/Windows (no native handlers) | False: `linux/runner/my_application.cc:25`, `windows/runner/flutter_window.cpp`, `android/.../MainActivity.kt` all implement `isClipboardSensitive`/`getClipboardImage`. The 750 ms poll itself is documented as deliberate (`docs/architecture/clipboard.md`). |
| `tool/deploy-all.sh` lacks `set -e` | By design: header says each target reports OK/SKIP/FAIL and the others still run; it has `set -uo pipefail` (line 29) and the remote script has `set -e` (line 105). |
| `user_e2ee_settings` lacks `force row level security` | False: `20261006200000_e2ee_encrypted_payload.sql:42` forces it. The hard-coded 7-table catalog test (finding 22) stands. |
| Backup import inflates a zip member fully in memory | Already tracked: issue #342. |
| iOS keyboard reads a stale clipboard mirror | Already tracked: issue #343. |
| Transport (http/https) not enforced for endpoints | Documented decision (`docs/architecture/settings-security.md`). |
| `record_linux` fork override, `share_plus` held at ^12, `prefer_const_constructors_in_immutables` off, repo not `dart format` clean | Documented decisions (`pubspec.yaml` comments, `analysis_options.yaml`, maintainer memory). |
| Vendored duplicates of pub packages | None found (cryptography, archive, sqlite3 all from pub; `native/` wraps whisper.cpp which is not on pub). |

## Not audited (standard effort; say so honestly)

- `lib/features/processing/` and most of `lib/features/transcription/` (`audio_splitter`, `audio_repairer`, `transcription_service`) — not opened by the correctness/security auditor.
- `lib/features/auth/` (OAuth redirect handling), `settings_repository.dart`, the two keyring master-key stores, `command_client.dart`, `terminal_launcher.dart`.
- `recordings_controller.dart` beyond roughly a third: enrichment, cleanup, vault mirror, embeddings, rerank, `refreshCommandOutcomes`, the backfills.
- `app_database.dart` past line 120 (legacy migration, schema, indexes).
- `supabase/tests/*.sql` beyond grep; `sync_push` dynamic-table allow-list (`20260921090000_sync_push.sql:17-28`).
- `native/` FFI buffer lengths beyond the whisper input copies; `tool/*.sh` with shellcheck (not installed).
- Any profiling: every performance finding is mechanism-level, unmeasured.
- Coverage: test findings are import-grep based, no `--coverage` run.
- `.env.local` exists in the tree listing; it was never opened (holds live credentials) and `git ls-files` shows no tracked `.env*`.

## How to use these plans

Each plan is self-contained: an executor with no context from this audit reads one file and has the why, the exact current-state excerpts, the repo conventions with an exemplar, ordered steps with a verification command each, scope boundaries, machine-checkable done criteria, a test plan, a maintenance note and escape hatches. Every plan stamps `294976b`; its Step 0 drift check tells the executor whether the excerpts still match.

Repo rules every plan assumes (from `CLAUDE.md` and the maintainer's global conventions): work in `.worktrees/<type>-<issue>-<slug>` branched from `origin/main`; the issue number in the branch name is mandatory; Conventional Commits with `Refs #<N>`; **no AI attribution in commits or PRs**; merge with `--no-ff`; `flutter analyze` + `flutter test` green before push; never `dart format` existing files; English-only strings; pure-Dart tests with hand-written fakes; poll, never sleep, for `Timer`-driven behaviour; look at the screen for UI work.

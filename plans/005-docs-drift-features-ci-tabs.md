# 005 — Bring the agent-facing docs back in line with the code

| Field | Value |
| --- | --- |
| Status | TODO |
| Written against | commit `294976b` (branch `main`), 2026-10-21 |
| Finding | docs (several high-confidence staleness items), S effort, zero code risk |
| Effort | S–M (2–5 h; the one new architecture doc is most of it) |
| Fix risk | none to runtime; a docs-only commit skips the pre-commit hooks' interesting paths but still runs `pre-push` (`flutter analyze` + `flutter test`) |
| Depends on | nothing. Do it **last** among the first batch, or the feature counts you fix may drift again. |

## Why this matters

`CLAUDE.md` is the entry point every agent (and `AGENTS.md`, its Codex twin) reads before touching this repo. It carries a pointer table and says "open the matching reference before changing anything in its area." Where the table is wrong, agents guess. Every item below was verified by grep at `294976b`.

| # | Claim | Reality | Where |
| --- | --- | --- | --- |
| 1 | "Eighteen features" (two places) and a list of 18 | `lib/features/` has **20**: `connections` and `work_dashboard` are missing from the list, the pointer table and `docs/architecture/` | `CLAUDE.md:90`, `CLAUDE.md:149` |
| 2 | "There is no server-side CI … parked at `.github/workflows/ci.yml.disabled`" | CI is live (`ci.yml` header line 1-5 says it was re-enabled); the `.disabled` file does not exist | `README.md:1200-1203`, `.githooks/pre-push:4-5` |
| 3 | "56 test files" | 218 `*.dart` files under `test/` (214 `*_test.dart`) | `README.md:1196` |
| 4 | "Local issue tracker (no GitHub remote yet). Move to `gh issue` once a remote exists." | `origin` is on GitHub with 30+ open issues | `ISSUES.md:3` |
| 5 | "seven bottom-nav tabs", table with 7 rows, "seven destinations" ×3 | `recordings_page.dart:186-197` has **8** destinations: QUEUE, TIMER, **WORK**, PROJECTS, CLIPBOARD, MODELS, LOGS, CONFIG | `docs/architecture/ui.md:5`, table at `:7-14`, `:38`, `:43` |
| 6 | "every capture pulled from Turso would be invisible" | the Turso path was removed in #202; sync is Supabase | `docs/architecture/persistence.md:28` |
| 7 | On-device transcription plan "Status: **proposed**"; `ISSUES.md:7-12` says local inference "needs a native dependency that is not in `pubspec.yaml` today" | shipped: `lib/features/transcription/data/whisper_ffi_engine.dart`, `whisper_model_store.dart`, `local_transcription_service.dart`, `ProfileKind.localWhisper`; CI runs a real transcription on macOS and Windows | `docs/plans/2026-08-16-on-device-transcription.md:3`, `ISSUES.md:7-12` |
| 8 | `AGENTS.md` (untracked in the working tree) is a copy of `CLAUDE.md` that lags it by four edits | `diff AGENTS.md CLAUDE.md` shows 5 hunks: the hook's secret-file refusal, `SupabaseConfig` key validation, the third removal path, the inbox pointer | repo root |

Not in scope (tracked elsewhere or a product decision): `CHANGELOG.md` stopping at 0.2.0 with 377 commits since the tag — the release procedure in that file says the entry is written at release time; `ux-debt.yaml`'s relationship to GitHub issues (direction item, see `plans/README.md`).

## Target state

1. `CLAUDE.md` says twenty features, lists `connections` and `work_dashboard` in both places, and the pointer table has a row for the new doc.
2. A new `docs/architecture/connections-work-dashboard.md` exists, written in the house style, covering both features (they are small: 420 + 630 lines).
3. `README.md` and `.githooks/pre-push` describe CI as live and the hook as the local fast gate.
4. `README.md` test-count line no longer states a number (numbers rot) — or states the current one if the maintainer prefers; default: drop the number.
5. `ISSUES.md` top says the tracker is GitHub (`gh issue list`) and that the file is historical; the "Open — On-device models" section is marked done with a pointer to the code.
6. `docs/architecture/ui.md` says eight tabs, table has 8 rows with `WORK` at index 2 and every later index shifted, and the three "seven destinations" phrases say eight.
7. `docs/architecture/persistence.md:28` says "pulled by sync" instead of "pulled from Turso".
8. `docs/plans/2026-08-16-on-device-transcription.md` status line says which slices shipped (read the plan's slice list and grep each slice's symbols; mark shipped/unbuilt per slice, do not invent).
9. `AGENTS.md`: regenerate from `CLAUDE.md` (`sed` the one differing line, see Step 6) **and commit it** so the two stop diverging — unless the maintainer intentionally keeps it untracked; it is untracked today, so ask in the PR description rather than assuming. Default: commit it.

## Conventions to follow

- House style for architecture docs: read `docs/architecture/clipboard.md` whole (it is ~12 paragraphs). Shape: one-line title, one-sentence summary, then bold-led bullets each stating a rule and **why it is that way**, naming the exact symbols and files. No marketing, no restating code; invariants and seams.
- English only. Numbers only where they are load-bearing (indices, capacities).
- Do not run a markdown formatter over existing files.
- Docs-only commit: `docs(...)` type, `Refs #<N>`; no AI attribution.

## Scope boundaries

In scope: the nine files named above, plus `docs/architecture/connections-work-dashboard.md` (new).

Out of scope — do not touch: any `lib/` or `test/` file; `CHANGELOG.md`; `ux-debt.yaml`; `docs/superpowers/`; other `docs/plans/*.md`; `README.md` beyond lines ~1190-1210 and the one Linux-prerequisite line (Step 4).

## Steps

### Step 0 — Drift check

```bash
git rev-parse --short HEAD
grep -c "ighteen" CLAUDE.md                     # expected 2
ls lib/features | wc -l                         # expected 20
grep -n "ci.yml.disabled" README.md .githooks/pre-push   # expected 2 hits
grep -n "seven" docs/architecture/ui.md | wc -l          # expected ≥ 3
grep -n "Turso" docs/architecture/persistence.md         # expected 1
```

If `ls lib/features | wc -l` is not 20, re-derive the feature list before editing (`ls lib/features`), and fix the count to whatever it is.

### Step 1 — Issue, worktree

```bash
gh issue create --title "Docs drift: feature count, CI status, tab table, Turso, on-device status" \
  --label documentation \
  --body "CLAUDE.md lists 18 of 20 features; README and pre-push say CI is parked; ui.md has 7 of 8 tabs; persistence.md cites Turso; on-device plan says proposed. Plan: plans/005-docs-drift-features-ci-tabs.md"
git fetch origin
git worktree add .worktrees/docs-<N>-drift -b docs/<N>-drift origin/main
cd .worktrees/docs-<N>-drift
```

No `flutter pub get` needed for docs, but the `pre-push` hook runs `flutter analyze` + `flutter test`, so run `flutter pub get` once before pushing.

### Step 2 — Read the two undocumented features

Read whole (they are short):

- `lib/features/connections/domain/daily_connections.dart` (42 lines): `ConnectionKind {sameTopic, complementary, differentAngle, appImprovement}`, `ConnectionGroup`, `DailyConnectionsReport`, `capturesOnDay(...)` (local calendar day, transcript non-empty), `DailyConnectionsService.review(day, captures, {projectNames})`.
- `lib/features/connections/data/http_daily_connections_service.dart` (204 lines): resolves the active **enrichment** profile at call time (resolver, not snapshot — the seam shape from `CLAUDE.md`), wraps the client in `BoundedClient` with `maxResponseBytes`, throws `ConnectionsNotConfiguredException` / `ConnectionsResponseException`, reports usage through `recordUsage` (the costs sink).
- `lib/features/connections/presentation/daily_connections_dialog.dart` (174 lines): the REVIEW CONNECTIONS / REVIEW DAY dialog reached from the Queue; report lives only in the open dialog.
- `lib/features/work_dashboard/data/todoist_reader.dart` (175 lines): read-only Todoist REST reader (`TodoistProject`, `TodoistTask`, `BoundedClient`), token read from `AppSecureStorage` under the key `todoist_read_token` (see `work_dashboard_tab.dart:40`).
- `lib/features/work_dashboard/presentation/work_dashboard_tab.dart` (454 lines): the WORK tab; maps a Todoist project to a Capture project **locally**, shows recent captures and completed focus sessions, manual refresh, rows open in Todoist via `url_launcher`.
- `README.md:195-214` already describes both features for users — reuse the facts, not the prose.
- Existing tests: `test/daily_connections_test.dart`, `test/connection_reasoner_test.dart`, `test/features/work_dashboard/work_dashboard_navigation_test.dart` — cite them.

Note the one structural fact worth recording: `work_dashboard` has **no `domain/`** layer (reader lives in `data/`, the tab talks to it directly). State it as a fact in the doc, not as a to-do.

### Step 3 — Write `docs/architecture/connections-work-dashboard.md`

~10–15 bullets in the `clipboard.md` style. Must cover, with symbols:

- Both are **read-only with respect to the capture pipeline**: neither writes `status`, a source file, or the index. The connections review never edits or merges captures; the dashboard never writes to Todoist (the token is a read token by name and by use).
- Connections: which captures qualify (`capturesOnDay`), which model runs it (active enrichment profile via resolver), the bounded client, the two failure types and their user-facing strings, usage reporting via the costs sink (shows in overall costs, not on a card — see `docs/architecture/costs.md`), the report is ephemeral (dialog-scoped).
- Work dashboard: the Todoist token's storage (`AppSecureStorage`, key name), the local Todoist-project→Capture-project mapping, manual refresh, what "due" counts mean (today or overdue), rows open externally.
- The missing `domain/` layer in `work_dashboard`, stated plainly.
- Tests that pin each.

### Step 4 — Edit the eight stale spots

1. `CLAUDE.md:90`: "Eighteen features: … `mcp`." → "Twenty features: … `mcp`, `connections`, `work_dashboard`." `CLAUDE.md:149`: "Eighteen features, seventeen lines" → "Twenty features, eighteen lines — `timer`/`momentum` share one, and so do `connections`/`work_dashboard`." Add the two bullets after `mcp` in that list, one line each, each ending with the new doc path. Add a pointer-table row: `| docs/architecture/connections-work-dashboard.md | features/connections/, features/work_dashboard/, the REVIEW CONNECTIONS dialog, the WORK tab, the Todoist reader |`.
2. `README.md:1196`: drop ` # 56 test files, pure Dart + widget` → ` # pure Dart by default, a few widget tests`. `README.md:1200-1203`: replace the paragraph with: CI (`.github/workflows/ci.yml`) runs analyze, test and the platform builds on every push to `main` and every PR; the `pre-push` hook runs the same analyze + test locally in seconds and is worth enabling. Keep the `git config core.hooksPath .githooks` block. While there, under the quickstart (`README.md:55-60`), add one line: "Linux: install `keybinder-3.0 libsecret-1-dev` first (see Build & deploy)."
3. `.githooks/pre-push:2-6`: rewrite the header comment: "Local fast gate. CI (`.github/workflows/ci.yml`) runs the same `flutter analyze` + `flutter test` on the server; this hook fails in seconds on the machine that broke the build instead of after a push and a runner spin-up. PR #9 shipped a branch that did not compile before this existed." Keep the enable/skip instructions.
4. `ISSUES.md:1-3`: "# Backlog — historical. Issues live on GitHub: `gh issue list`. This file is kept for the 'Done' notes below and is not maintained." Under "## Open — On-device models": retitle "## Done — on-device models" and replace the body with two lines pointing at `lib/features/transcription/data/whisper_ffi_engine.dart`, `whisper_model_store.dart`, `ProfileKind.localWhisper`, and the invariant sentence (keep it — it is still true).
5. `docs/architecture/ui.md:5`: "seven bottom-nav tabs" → "eight bottom-nav tabs"; "including the six that are off screen" → "seven". Table `:7-14`: insert `| 2 | Work | work_dashboard/presentation/work_dashboard_tab.dart | TodoistReader + ProjectsController + RecordingsController + FocusTimerController |` and renumber Projects→3, Clipboard→4, Models→5, Logs→6, Config→7 (read the table to the end first — rows 5-7 are below line 14). `:38`, `:43` (twice): "seven" → "eight". Also grep `ui.md` and `clipboard.md` for "tab 3" (clipboard.md:5 says Clipboard is tab 3; it is now index 4) and fix.
6. `docs/architecture/persistence.md:28`: "every capture pulled from Turso would be invisible" → "every capture pulled by sync would be invisible".
7. `docs/plans/2026-08-16-on-device-transcription.md:3`: change `Status: **proposed**` to `Status: **shipped (slices …)** · remaining: …` after checking each slice heading in that plan against the code (grep the symbols the slice names). If a slice's status is unclear, write "unverified" for that slice rather than guessing.
8. `AGENTS.md`: regenerate:
   ```bash
   sed -e '1s/CLAUDE.md/AGENTS.md/' \
       -e '3s/Claude Code (claude.ai\/code)/Codex (Codex.ai\/code)/' CLAUDE.md > AGENTS.md
   diff <(sed -e '1s/AGENTS.md/CLAUDE.md/' -e '3s/Codex (Codex.ai\/code)/Claude Code (claude.ai\/code)/' AGENTS.md) CLAUDE.md && echo identical
   git add AGENTS.md
   ```
   Expected: `identical`. State in the PR that `AGENTS.md` was untracked and is now committed as a generated twin, and that the maintainer can drop it from the commit if it is meant to stay local.

### Step 5 — Verify

```bash
grep -c "ighteen" CLAUDE.md                                   # 0
grep -c "connections-work-dashboard.md" CLAUDE.md             # ≥ 3 (table row, two feature bullets)
test -f docs/architecture/connections-work-dashboard.md && wc -l docs/architecture/connections-work-dashboard.md   # ≥ 25 lines
grep -rn "ci.yml.disabled" README.md .githooks/pre-push       # 0
grep -n "seven" docs/architecture/ui.md                       # 0 hits about tabs/destinations (other uses of "seven" are fine; read them)
grep -n "Turso" docs/architecture/persistence.md              # 0
grep -n "no GitHub remote" ISSUES.md                          # 0
grep -n "^Status:" docs/plans/2026-08-16-on-device-transcription.md   # no longer "proposed"
flutter analyze && flutter test                               # unchanged, green (hook will run them anyway)
```

### Step 6 — Commit

```
docs: fix feature count, CI status, tab table and stale sync names

Twenty features, not eighteen: connections and work_dashboard get a
reference doc and pointer rows. README and the pre-push header said CI
was parked; it has been live since the repo went public. ui.md gains the
WORK tab at index 2. persistence.md no longer cites Turso. ISSUES.md
points at GitHub and marks on-device transcription done. AGENTS.md is
regenerated from CLAUDE.md and committed.

Refs #<N>
```

## Done criteria

Everything in Step 5 passes, `git diff origin/main --stat` lists only the ten files named in scope, and `flutter analyze` + `flutter test` are unchanged-green.

## Maintenance note

`CLAUDE.md`'s feature count and `ui.md`'s tab table are the two spots that rot every time a feature or tab lands. Reviewers: a PR that adds a directory under `lib/features/` or a destination in `recordings_page.dart:186-197` must touch `CLAUDE.md` (count, list, table) and `ui.md`. `AGENTS.md` is generated from `CLAUDE.md` by the one-line `sed` in Step 4.8 — edit `CLAUDE.md`, regenerate, never edit `AGENTS.md` by hand.

## Escape hatches — STOP and report if

- `ls lib/features` shows a count other than 20, or a feature with no `presentation/` **and** no mention anywhere in `docs/` — list it instead of inventing a description.
- The on-device plan's slice list cannot be matched to code in ~20 minutes of grepping — leave the status line as "proposed; parts shipped, see `lib/features/transcription/`" and say so.
- `AGENTS.md` turns out to be tracked on `origin/main` by the time you run (it is untracked at `294976b`) — then diff against the tracked version and update rather than regenerate blindly.

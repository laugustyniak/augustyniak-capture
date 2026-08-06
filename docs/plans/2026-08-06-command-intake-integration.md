# Plan: hand off to Command instead of launching the session ourselves

Status: **proposed** · Owner: laugustyniak · Scope: `agentTask` captures leave
through the Command control plane and report an outcome back, and the
Ghostty/Zellij launcher is demoted to the offline case it is actually good at.

> The contract this implements is **RFC-0008** in the Augustyniak Command repo
> (`docs/rfc/0008-capture-intake-contract.md`, issue #87). Where this plan and
> that document disagree, the RFC is the contract and this file is the bug —
> it is normative on the other side of an HTTP boundary neither repo can test
> for the other.

## Motivation

Two things are true at once, and both are in this repo's own documents.

**We start agent sessions badly.** `GhosttyZellijAgentSessionLauncher` opens a
named Zellij session in the project directory and starts one CLI. That is
macOS-only, single-machine, and the moment it returns the session leaves our
field of view: `docs/agent-sessions.md` has to tell the user that a second
hand-off cannot deliver a prompt to a running session and that they should copy
it by hand. Command's control plane spawns into tmux on any host, keeps the
session in a fleet snapshot, offers a terminal view and history, and refuses a
second start with the id of the one already running.

**We promised nothing comes back, and meant it.**
`docs/plans/2026-08-05-handoff-vocabulary-design.md` chose `hand off` over
`delegate` precisely because *"nothing returns — there is no outcome field and
no return path"*, and named what would have to change if one were ever built:
`RouteRecord` grows a result and `handedOff` stops being terminal. Command has
that result already — issue labels, a handoff file, a PR link — and it is
durable in GitHub rather than in either app.

So: stop competing on execution, start consuming the outcome.

## What does not change

Stated first, because this plan touches the capture path and that path is the
reason the app exists.

- **The seven steps are untouched.** `stopRecording()` and `addTextNote()` keep
  create → finish → verify → persist → queue → process. Nothing here runs before
  a capture is on disk. A hand-off is an action on a *reviewed* row, minutes or
  days later.
- **No new token type, no new failure mode for capture.** The fleet token is
  stored exactly like a provider token: `TokenCipher`, AES-256-GCM under the OS
  keyring, `enc:v1:` prefix, plaintext fallback said out loud in Config.
- **Offline still works.** No control plane configured, or unreachable: the
  capture stays on the desk, retryable, and the local launcher is still there.
  This is the existing `CaptureRouter` contract — *delivery first, state second,
  a throw leaves the item open* — and it is not weakened.
- **No GitHub token in this app.** Ever. That was the reason `inbox.md` beat a
  tracker API, and Command exists so it stays true.
- **`recordings.json` stays backward compatible.** One optional field is added
  to `RouteRecord`; every `fromJson` keeps defaulting rather than dropping.

## Design: one more destination behind the seam we already have

`CaptureRouter` is the seam, and it was built for exactly this — the README's
roadmap already says *"Notion and tracker destinations behind the same
`CaptureRouter` seam"*. Command is the first of those, and it needs no new
architecture:

```
RecordingsController
        │  route(RoutedCapture)
        ▼
   CaptureRouter  ◀── the existing seam, unchanged
        ├── ProjectInboxRouter    (today) — appends to inbox.md
        ├── CommandRouter         (new)   — PUT brief, POST session
        └── DisabledCaptureRouter (today) — no destination
```

Which router a capture gets is decided by its **project**, not by its category
alone: a bound project (`commandWorkspace` set) sends `agentTask` to
`CommandRouter` and everything else to `ProjectInboxRouter`; an unbound project
behaves exactly as today. That keeps one decision point rather than a condition
repeated per surface.

**`canRoute` stays synchronous, and that matters.** The card gates its button on
it inside `build`. `CommandRouter.canRoute` therefore answers from the project's
configuration — is this project bound? — and never from the network. This is not
a compromise: the seam's own docstring already says *"Destinations are
configuration, not state"*. A capture whose project is bound but whose collector
is down gets an enabled button and a failed delivery that leaves it on the desk,
which is the correct shape.

### The two calls

```
PUT  {aggregator}/api/{host}/workspaces/{workspace}/briefs
     {content: "<the brief markdown>", capture_id: "<uuid>"}
  → 201 {brief_id, path}

POST {aggregator}/api/sessions/{host}
     {workspace, engine: "command-plan", prompt: "<brief_id>"}
  → 201 {tmux_session, pid}
```

Both carry the fleet token as a bearer. The PUT is idempotent on `capture_id`,
which is what makes our existing retry contract safe: a timed-out delivery is
retried by the user and must not produce two briefs and two planning sessions
from one thought.

### The brief is the format we already write

`.agent-tasks/<capture-id>.md` already exists and already carries title,
summary, tags and the transcript — that is why a twenty-minute dictation travels
intact. RFC-0008's brief is that file with YAML front matter on top. **Slice 0
below writes the new format for the local launcher too**, so there is one
serializer and one format, and the API path is not the only thing that gets it
right.

```markdown
---
capture-id: 3f2a1c4e-…-c81b
created: 2026-08-05T14:32:11.482Z
source: audioRecording
category: agentTask
tags: ["backend", "migration"]
intent: "only write tests"
---

# Split the router before the index work lands

> Migration deferred until index durability lands; router split agreed.

We agreed to postpone the migration…
```

`intent` is the hand-off sheet's editable one-liner — the `only write tests` /
`open a PR when green` field that sheet already offers. Command passes it to the
planner as a hint, explicitly not a constraint.

### The return path

```
GET {aggregator}/api/briefs/{brief_id}
  → {state, issues: [...], pr_url, updated_at}
```

Polled on foreground and on pull-to-refresh. **Never on a background timer**:
nothing here is worth a wake-up, and a phone that polls a homelab on a schedule
is a battery cost with no user waiting on the answer.

`RouteRecord` gains one optional field:

```dart
class RouteOutcome {
  final String briefId;
  final CommandState state;   // submitted | planned | inProgress
                              // | done | blocked | needsReview
  final List<int> issues;
  final String? prUrl;
  final DateTime checkedAt;
}
```

Rendered as **one line** on the capture, plus a deep link into the Command PWA.
Not a fleet view: that exists, it is installable on the same phone, and
rebuilding it in Flutter is the overlap this whole plan is written to avoid.

### `RouteKind.command` and the one real compatibility cost

`RouteKind.fromName` returns null for an unknown name and **the caller drops that
row** — deliberately, and documented as such: claiming a capture went to a file
when a newer build sent it elsewhere would be worse than admitting the row is
unreadable.

The consequence is concrete and worth stating before it is discovered: **a
capture handed to Command and then opened in an older build loses that route
record.** The item itself survives, `isProcessedByUser` still says it is off the
desk, and only the "where did it go" line disappears — the same bounded loss the
enum's docstring already accepts.

Two alternatives were considered and rejected:

- **Reuse `RouteKind.agent`.** It means "handed to a coding agent as the opening
  prompt of a session", which is not what happens — Command receives a brief and
  *plans issues from it*; a session may not start for hours. Filing the two under
  one kind would make the outcome field's absence unexplainable on the old rows.
- **Make `fromName` default to `file`.** Rejected by the enum's own docstring,
  for the reason written there.

## Slices

Each ships alone and leaves the app working with no control plane anywhere.

### Slice 0 — the brief format, with no networking at all

Write the front matter into `.agent-tasks/<capture-id>.md`, used by the *existing*
local launcher. No new dependency, no settings, nothing to configure.

- New: `lib/features/projects/domain/capture_brief.dart` — pure Dart, builds the
  markdown from a `RoutedCapture` plus `intent`.
- Changed: the hand-off sheet's writer uses it.
- Tests: front matter round-trips; a `---` inside a transcript does not become a
  delimiter; Polish diacritics survive; appending a second `## Handoff` leaves
  everything written underneath intact (today's behaviour, now pinned).

Value on its own: the brief becomes readable by `augustyniak-command plan --brief`, which
already exists on the Command side. A user with `ssh` can pipe it today.

### Slice 1 — the client and the binding

- New: `lib/features/command/data/http_command_client.dart` +
  `lib/features/command/domain/command_client.dart` (the seam; the disabled
  default answers "not configured").
- New in Config: aggregator base URL + fleet token, stored through `TokenCipher`
  like every other token, with the same keyring status line.
- Changed: `Project` gains `commandHost`, `commandWorkspace`, `commandBoundAt` —
  all optional, all absent-tolerant in `fromJson`, `repoPath` still authoritative
  for `inbox.md` and the local launcher.
- The binding UI is **two pickers over live reads** (`GET /api/hosts`, then that
  host's workspaces), never a typed name. A typed workspace is a third source of
  truth with no validation, which is the drift this binding exists to prevent.
- Tests: client against a fake HTTP layer only — no real socket, in keeping with
  the pure-Dart suite. Unbound projects serialize byte-identically to today.

### Slice 2 — `CommandRouter`

- New: `lib/features/recordings/data/command_router.dart` implementing
  `CaptureRouter`. `canRoute` = project is bound. `route` = PUT then POST, throw
  on either, `RouteRecord(kind: command, target: "<host> · <workspace>")`.
- Changed: router selection per capture — bound project + `agentTask` → Command;
  everything else unchanged.
- Tests: PUT failure routes nothing and records nothing; PUT success + POST
  failure surfaces an error naming that the brief landed but no session started
  (the user must be able to tell "lost" from "queued but unstarted"); a retried
  hand-off with the same `capture_id` sends the same key.

### Slice 3 — the outcome

- New: `RouteOutcome` on `RouteRecord`, optional and absent-tolerant.
- New: a poll on foreground and pull-to-refresh, one line on the capture, deep
  link to the PWA.
- Tests: an unreachable aggregator keeps the last known outcome and its
  `checkedAt` rather than clearing it; a 404 (workspace unregistered) stops the
  polling instead of retrying forever.

### Slice 4 — demote the launcher

- `GhosttyZellijAgentSessionLauncher` is reached only for **unbound** projects.
- The hand-off sheet says **local session — not supervised** when that is the
  path it is about to take. Without the label the two paths look identical and
  differ in whether anything will ever report back.
- `docs/agent-sessions.md` is rewritten to say when each path applies.
- No features are added to the launcher. Not more agents, not more hosts, not
  status. Every one of those exists on the other side.

## Files

New: `lib/features/command/{domain,data}/`,
`lib/features/projects/domain/capture_brief.dart`,
`lib/features/recordings/data/command_router.dart`.

Changed: `lib/features/projects/domain/project.dart`,
`lib/features/projects/data/projects_repository.dart`,
`lib/features/recordings/domain/route_record.dart`,
the hand-off sheet and the capture card's status line,
`lib/features/settings/` (aggregator URL + token),
`docs/agent-sessions.md`, `README.md`.

Untouched: `RecordingsController`'s capture path, the processor registry,
enrichment, the note vault, `revisions.jsonl`.

## Not in scope

- **Starting, stopping, or pausing runs.** RFC-0008 gives Capture read access to
  a run and no writes. When to work the queue is a fleet decision made with a
  fleet view we do not have.
- **Creating GitHub issues directly.** No token, by design.
- **A fleet view in Flutter.** One status line and a deep link.
- **Reporting focus-timer minutes as attention telemetry.** It is a genuinely
  good fit and it is deliberately deferred: RFC-0007 merges attention across
  client instances rather than summing it, and a naive report would double-count
  every minute spent with both the dashboard and this app open — making the
  metric worse than reality in exactly the case the integration improves.
- **Renaming anything.** `isProcessedByUser`, the app identifier, and the
  `DESK`/`OFF DESK` vocabulary all stay.

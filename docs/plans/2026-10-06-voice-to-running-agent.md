# Plan: voice commands to an already running agent

Status: **proposed** · Owner: laugustyniak · Refs #256 · Scope: a dictated
capture can be addressed to the agent session that is already working on a
project, instead of opening a new one. The capture stays a capture; delivery is
a second, reviewed step.

> The control-plane half of this is a **change to RFC-0008** in the Augustyniak
> Command repo (`docs/rfc/0008-capture-intake-contract.md`). The RFC is
> normative: this file proposes the addition, Command accepts or amends it, and
> slice 3 does not start until that RFC change is merged. Where the two
> disagree, the RFC is the contract and this file is the bug.

## Motivation

Every route out of the queue today starts something. `ProjectAgentHandoff`
opens a new Zellij session; `CommandRouter` files a brief and starts a planning
session. Neither can say *"also add a test for Y"* to an agent that is already
mid-task. `docs/agent-sessions.md` says so plainly: a second hand-off to a live
session "attaches to a live session, delivering nothing", and the sheet stays
open so the user can paste by hand. `CommandClient` has `putBrief`,
`startSession` and `briefStatus` and no call that addresses a running session.

The use is exactly where typing is worst: dictating on a phone or a watch, or
from a desktop hotkey while the terminal is on another screen, a constraint or
an answer to the agent's question.

## What does not change

- **The five capture steps are untouched.** A command capture is obtained,
  verified (exists, length > 0), built as `saved`, persisted with `saveAll()`,
  and only then enqueued for transcription. Nothing is delivered before the
  audio is on disk, and **nothing is delivered before the transcript exists**,
  because the thing delivered is text.
- **Delivery is not processing.** Like `CaptureRouter.route()` it is *delivery
  first, state second*: a throw leaves the item open, unrouted and retryable
  with only `error` set. A failed delivery never touches `status` and never
  deletes a source.
- **No new token type.** The fleet token stays the one `TokenCipher` stores for
  `HttpCommandClient`.
- **The local launcher gains no hosts, no status, no reporting.** It gains one
  narrow capability, below, because `docs/agent-sessions.md` excludes a second
  prompt from it only on the grounds that Command provides one. Command does
  not yet (that is this plan's RFC gap), and offline is the case the launcher
  is for.
- **`recordings.json` stays backward compatible.** One optional field, absent
  from the JSON of every ordinary capture, so such rows serialise byte for byte
  as before.

## Design

### A command capture is told apart explicitly, at capture time

Three options were weighed.

| Option | Verdict |
| --- | --- |
| **Explicit mode**, chosen before recording | **Chosen** |
| Spoken prefix ("project X agent: ...") | Rejected |
| Enrichment intent (a new `CaptureCategory`) | Rejected |

- **A prefix** needs the transcript to exist before anything knows where the
  capture is going, so the routing decision rests on a speech-to-text guess at
  a project name. A mistranscribed prefix sends a typed instruction to the
  wrong session, or sends an ordinary note to a live agent.
- **An enrichment intent** is asynchronous, best-effort, and can be wrong by
  design (`category` already means "the model looked"). The enrichment input is
  also the capture's own text, so a captured web page or OCR'd image could
  *induce* the label `command`. Enrichment is **forbidden from ever selecting
  this**. A live session is a destination the user picks, not one a model
  infers.
- **Explicit mode** is known before the first byte is recorded, survives a
  failed transcription, and can be a distinct button, hotkey or menu entry.

Shape: `Recording.commandTarget` (`AgentCommandTarget?`, in
`recordings/domain/agent_command.dart`). **Absent means "an ordinary capture"**
and the key stays out of the JSON (the same absent-vs-empty rule `segments`
follows). Present, it carries `projectId` and an optional `sessionHint`. The
project is fixed at capture time from the active project, never parsed from the
words. `AgentCommandTarget.fromJson` degrades: a malformed target drops to
`null`, which turns a command back into an ordinary capture, never into a lost
row. Enrichment, `category` and the queue see an ordinary capture; the card
adds a `TO AGENT` chip and a `SEND` button.

### Delivery is reviewed by default

A transcript is not a command until a human has seen it. Speech-to-text turns
"don't delete the migration" into the opposite often enough to matter, and the
receiving end is a process that acts. So:

- Default: transcript lands, card shows `TO AGENT · <project> · <agent>` with
  the text editable, one tap on `SEND`. (The inline editor already exists, and
  edits write `revisions.jsonl` like any other.)
- Opt-in per project: **auto-send**, off by default, and **never** available
  when the permission rule below applies.

### The seam

```
RecordingsController.sendToAgent(id)        // like route(), after the item is persisted
        |
        v
   AgentMessenger (domain)                  // new seam, default degrades
        |-- DisabledAgentMessenger          // no destination; control hidden
        |-- ZellijAgentMessenger            // local, unbound project
        '-- CommandAgentMessenger           // bound project, via CommandClient
```

`AgentMessenger.canMessage(projectId)` is **synchronous** and answers from
configuration only, like `canRoute` and `canHandoff`. `message(request)`
throws on failure and the caller records nothing. On success it appends
`RouteRecord(kind: RouteKind.sessionMessage, target: '<agent> · <session>')` and sets
`isProcessedByUser`, exactly as `route()` does. Routing twice appends; both
deliveries happened.

`RouteKind.sessionMessage` is a new kind rather than a reuse of `agent` or `command`:
those mean "a session was opened" and "a brief was filed". The cost is the one
`RouteKind.command` already accepts, stated up front: an older build drops the
record (`fromName` returns null); the capture survives. `_closureKindFor` maps
it to `ClosureKind.handoff`.

### Which session, and what if none is running

The target is **a project's running session**, never something named in speech.

- **Bound project (Command):** list the workspace's sessions. Exactly one
  running: use it. More than one: the send sheet asks, and remembers the
  choice for that capture only. A stored `sessionHint` is an id to *prefer*,
  verified against the list each time (sessions end).
- **Unbound project (local):** the session name is
  `ZellijAgentSessionLauncher.buildSessionName(...)` for the project's default
  agent, the same function the launcher uses, so the two cannot disagree.
  Existence is checked with `zellij list-sessions --short --no-formatting`,
  as `_sessionExists` does.

**No running session: ask, never start silently.** Starting an agent is a much
larger act than relaying a sentence, and a *voice* command that spawns a
process (possibly with permissions skipped) on a misheard word is the wrong
default. The delivery throws `NoRunningSessionException`; the capture stays
open and retryable and the card shows `no running session`. The send sheet then
offers **START ONE WITH THIS AS THE FIRST PROMPT**, which is the existing path:
`ProjectAgentHandoff.handoff` for an unbound project, `putBrief` plus
`startSession` for a bound one, with the transcript as the prompt. That is a
separate tap that records `RouteKind.agent` or `command`, not `sessionMessage`.

### Local Zellij: what is safe and what is not

Two separate hazards. The first is the one the issue names.

**1. Shell injection: removed by construction.** The text is never part of a
string any shell parses. `ProcessRunner.run(executable, arguments)` is already
an argv-array seam (`SystemProcessRunner`), the same discipline the Linux
terminal table enforces. The call is

```
<zellij> --session <name> action write-chars -- <text>
```

with `<zellij>` from `PathExecutableResolver` and `<name>` a project-derived
slug. Text beginning with `-` is protected by `--`, and (because the project
already distrusts `--` across three CLIs) by `disarmOptionLookalike` as well.
**Size:** argv is capped by `ARG_MAX`. Above 4 KB the messenger does not send the text.
It sends a one-line pointer, `Read .agent-tasks/<capture-id>.md`, after
`renderCaptureBrief` has appended the text there. That reuses the brief writer and
the append-only rule, and it is the same file the attach path already falls back on.

**2. Terminal-control injection: this one is real and needs code.** The bytes
reach the agent's TUI as if typed. A transcript (or edited text) containing
ESC sequences, `\r` or `^C` would be interpreted. The messenger therefore:

- strips every C0 control except `\n`, and DEL;
- wraps the text in a **bracketed paste** (`ESC[200~` ... `ESC[201~`, sent as
  raw bytes with `zellij action write 27 91 50 48 48 126`), so embedded newlines
  are text, not Enter;
- sends the submit as a **separate** `write 13` after a verified paste. Because
  ESC has been stripped from the text, it cannot close the paste early.

**3. Pane targeting: the unsolved part, and it gates the slice.**
`write-chars` writes to the *focused* pane of the named session. The launcher's
layout is one pane running the agent directly (no shell), so by default the
focus is the agent. But a user may split a pane and focus a shell, and then a
voice transcript plus Enter becomes **a shell command**. There is a second trap:
a Zellij command pane whose process exited waits for Enter to *re-run* it, with
the original arguments, including any skip-permissions flag. Slice 0 is
therefore a spike answering, against the installed Zellij, whether a pane can be
addressed by id and its running command read (`dump-layout`, `list-clients`,
`--pane-id` where available). **Rule regardless of the answer:** the messenger
refuses unless the session has exactly one terminal pane and that pane's command
is the agent executable; anything else raises `SessionNotSafeToInjectException`
and the card offers copy-to-clipboard, the behaviour that exists today. If the
spike shows this cannot be verified, local delivery does not ship and the local
path stays copy-and-paste. Command's tmux path is not subject to this because
the RFC addresses a session by id (below).

Only sessions this app launched are targeted (name derived, not typed).
Windows has no Zellij, so `canMessage` is false there, as `canHandoff` is.

### Permission-skipping sessions

`Project.settingsFor(agent).skipPermissions` maps to `--dangerously-skip-permissions`
and Codex's `--dangerously-bypass-approvals-and-sandbox`
(`ProjectAgent.skipPermissionsArguments`). Injecting text into such a session
turns a transcription into an unattended action: no approval prompt stands
between the words and the file system. Rules:

- **Auto-send is disabled** for any session known or presumed to skip
  permissions. Review is mandatory, not a default.
- **Send needs a second, explicit confirmation** that says so in words: the
  sheet prints `This session skips permission prompts. This text will run
  without approval.` The button is labelled accordingly.
- **Unknown is treated as skipping.** Locally, the flag is known only from the
  project's current settings, which may differ from how a still-running session
  was launched; if they are not clearly off, treat as on. For Command, the
  session object must report `permission_mode` (RFC below); absent means
  "assume skipped".
- **Provenance is visible.** The delivered text is marked in the session as
  originating from a voice capture (Command records the source; locally the
  paste is preceded by nothing the agent could mistake for its own output, and
  the brief file carries `source: audioRecording`).
- **Captured content never joins the message.** Only the user's own transcript
  is sent; OCR text or a pasted page is never appended or inlined. This is the
  vector the existing `disarmOptionLookalike` note records.

### The RFC-0008 addition (cross-repo)

New endpoint, bearer-authenticated like the others:

```
GET  {aggregator}/api/{host}/workspaces/{workspace}/sessions
  -> 200 [{session, agent, state, permission_mode, started_at}]
     state: running | idle | waiting_for_input | ended
     permission_mode: default | skip | unknown

POST {aggregator}/api/sessions/{host}/{session}/messages
     {capture_id, text, source: "voice-capture", expect_workspace}
  -> 201 {message_id, delivered_at}
  -> 200 (same body) when capture_id was already delivered   # idempotent
  -> 404 {code: "no_such_session"}      # never existed, or ended
  -> 409 {code: "not_accepting", state} # ended, or mid-tool-call and refusing
  -> 422 {code: "too_large"}            # over a stated byte limit
```

Normative requirements for the Command side:

- **Idempotent on `capture_id`**, the same guarantee `PUT .../briefs` has. This
  is what makes our retry contract safe: a timed-out delivery that actually
  landed must not type the instruction twice.
- **Missing session is reported, not queued.** 404 and 409 are distinct from a
  transport failure, and the collector must not buffer the message for a future
  session. A message to nothing is a mistake the user must see.
- **`expect_workspace` is checked** against the session's workspace, so a stale
  host/session pair cannot deliver across projects.
- Delivery is `tmux load-buffer` + `paste-buffer -p` or `send-keys -l`, with
  the text as an argv element or stdin, never interpolated into a shell string,
  and the same control-character stripping. The RFC states this requirement
  because this repo cannot test the other side.
- The message is appended to the session history with `source`, so a human
  reading the transcript can tell dictated input from typed.
- `permission_mode` is **reported**, and unknown is a valid value.

`CommandClient` gains `sessions(host, workspace)` and `sendMessage(...)`;
`DisabledCommandClient` throws `CommandNotConfiguredException` as for every other
call, and `HttpCommandClient` maps 404 to `NoRunningSessionException`, 409 to
`SessionNotAcceptingException`, and leaves transport errors as themselves so the
caller can retry. The route record's `target` names the session so the user
sees where it went.

## Slices

Each ships alone and leaves the app working with none of the others.

### Slice 0 - the Zellij spike and the sanitiser (no UI)

- New: `lib/features/projects/domain/terminal_input.dart` -
  `sanitiseForTerminal(String)` and `bracketedPaste(String)`, pure Dart.
- Decide, with a recorded transcript of `zellij action` calls, whether pane
  identity can be verified. Written up in `docs/architecture/agent-handoff.md`.
- Tests (`test/terminal_input_test.dart`): ESC and C0 stripped; `\n` kept; a
  forged `ESC[201~` inside the text cannot end the paste; NUL refused;
  leading `-` survives as text; Polish diacritics survive.

### Slice 1 - the mode, persisted (no delivery)

- New: `AgentCommandTarget` in `recordings/domain/agent_command.dart`.
- Changed: `Recording` gains optional `commandTarget`; `startRecording` and
  `addTextNote` accept it and write it at the `saved` step.
- Tests: `test/agent_command_test.dart` - round trip; **legacy JSON has no key
  and defaults to ordinary**; an ordinary capture serialises byte for byte as
  before; a malformed target degrades to `null`, not a dropped row; the target
  is on disk (`saveAll` called) before `_enqueueProcessing`; a failed
  transcription keeps the target and the source; enrichment never sets it.

### Slice 2 - `AgentMessenger` and local delivery

- New: `recordings/domain/agent_messenger.dart` (seam, `Disabled...`, the three
  exceptions), `recordings/data/zellij_agent_messenger.dart`.
- Changed: `RecordingsController.sendToAgent(id)` (delivery first, record
  second, a throw leaves it open); `RouteKind.sessionMessage` and its
  `ClosureKind.handoff` mapping.
- Tests (`test/zellij_agent_messenger_test.dart`, fake `ProcessRunner`): the
  text appears only as an argv element, never in a joined string; no session
  throws `NoRunningSessionException` and records nothing; more than one pane or
  a non-agent command refuses; 4 KB boundary writes the brief and sends a
  pointer; failure leaves the item unrouted with `error` set; two sends append
  two records. `RouteKind.sessionMessage` row dropped by an unknown-name test, kept by
  a known one.

### Slice 3 - Command delivery (blocked on the RFC-0008 change)

- Changed: `CommandClient`, `HttpCommandClient`, `DisabledCommandClient`;
  New: `recordings/data/command_agent_messenger.dart`.
- Tests: 404 to `NoRunningSessionException`; 409 to `SessionNotAccepting`; a
  timeout leaves the item open; a retry sends the same `capture_id`; a
  duplicate `200` is treated as success; `expect_workspace` is always sent; no
  socket is opened (fake `http.Client`).

### Slice 4 - the permission rule

- New: `AgentMessenger.permissionRiskFor(...)` answers `none | skips | unknown`;
  the controller enforces "review required" independent of the UI.
- Tests: `skipPermissions` project, or unknown `permission_mode`, refuses
  auto-send even when the project opted in; a sheet-less `sendToAgent` call on a
  skipping session without the confirm flag throws.

### Slice 5 - the controls

- Changed: capture menu entry **Command to agent**; the queue card's
  `TO AGENT` chip, `SEND` action, the send sheet (session picker, confirm line,
  START ONE fallback); `ShortcutAction.sendToAgent`, which starts a recording
  in command mode (`needsWindow` false, the same asymmetry as
  `toggleRecording`, so the mic is not delayed).
- Tests: `ShortcutAction.fromName` still drops unknown names; the hotkey calls
  the same controller entry as the menu; widget tests per
  `docs/architecture/testing-widgets.md` for the sheet and the confirmation.
- **Look at it running** in both themes before calling it done.

### Slice 6 - the watch (deferred)

`android/wear` records locally and has no phone link ("Not built ... To agent");
a watch has no project picker. Nothing to build until phone sync (#229) lands,
and then the shape is: the phone, which knows the active project, stamps the
`commandTarget` when it adopts a watch capture flagged as a command. Out of
scope here.

## Files

New: `lib/features/recordings/domain/{agent_command,agent_messenger}.dart`,
`lib/features/recordings/data/{zellij,command}_agent_messenger.dart`,
`lib/features/projects/domain/terminal_input.dart`.

Changed: `recordings/domain/{recording,route_record}.dart`,
`recordings_controller.dart` (`sendToAgent`), `features/command/**`,
`features/shortcuts/domain/shortcut_action.dart`, the card and the send sheet,
`docs/architecture/agent-handoff.md`, `docs/agent-sessions.md`, `README.md`.

Untouched: the capture path through step 5, the processor registry, enrichment
(it may not set the mode), `revisions.jsonl` (only the usual edit entries).

## Not in scope

- **Parsing the project or session from speech.** Chosen in the UI.
- **Starting a session from a command without a tap.** Missing session means ask.
- **Streaming the agent's reply back.** One status line at most, as with briefs.
- **Cancel or interrupt** (`^C`) and **answering permission prompts by voice**.
  The second would let speech approve an action; that is deliberately never built.
- **Unreviewed delivery to a session skipping permissions**, in any
  configuration.
- **tmux support in this app.** Command owns tmux; this app owns Zellij.

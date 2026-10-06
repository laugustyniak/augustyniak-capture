# Plan: tracker destinations (Linear, Notion) and where GitHub Issues goes

Status: **proposed** · Owner: laugustyniak · Scope: a capture can leave the
queue as an issue in Linear or a page in Notion, with an agent-formatted body,
behind the existing `CaptureRouter` seam. GitHub Issues gets **no destination of
its own**. Refs #254.

## Motivation

A capture can leave the queue three ways today: appended to `inbox.md`
(`ProjectInboxRouter`), opened as a local agent session, or filed as a brief with
Command (`CommandRouter`). A task that belongs in a tracker still has to be
copied by hand, which is the chore `isProcessedByUser` was a stand-in for before
routing existed. The README roadmap already lists *"Notion and tracker
destinations behind the same `CaptureRouter` seam"*.

Two things make this different from `inbox.md` and from Command, and the plan is
mostly about them: a tracker API needs a **token this app would hold**, and a
tracker call can **time out after it succeeded**.

## What does not change

- **Persist before process.** Nothing here runs before a capture is on disk and
  `completed`. A route is an action on a reviewed row, later. `stopRecording()`,
  `addTextNote()` and the five steps are untouched.
- **Delivery first, state second.** `RecordingsController.route()` calls the
  router, and only then appends the `RouteRecord` and sets `isProcessedByUser`.
  A throw leaves the item open, unrouted and retryable, with only `error` set.
  Every tracker router keeps that contract, including for a reply it cannot read.
- **No GitHub token in this app. Ever.** See the first question below.
- **A processor still never writes the source;** a tracker router reads the
  `RoutedCapture` and never touches a file.
- **Offline still works.** No tracker configured, or unreachable: the capture
  stays on the desk and `inbox.md` is still there.

## Questions the issue asks

### 1. GitHub Issues: through Command, or not at all?

**Not a destination in this app. The route is Command, and it already exists.**
`CommandRouter` files a brief; Command plans GitHub issues from it, holding the
token on a host the user owns. Adding `GithubIssuesRouter` would put a repo-scoped
token in the OS keyring of a phone, which is the exact trade `inbox.md` was chosen
over, and the command-intake plan states it as a standing rule.

What the user loses is a *direct, unplanned* issue: Command plans a brief into
issues rather than filing one verbatim. If that turns out to matter, the fix
belongs in the Command repo (an RFC-0008 intake mode that files the brief as a
single issue, titled and bodied as sent). **This plan does not request that.** It
is named here so the gap is a decision rather than an omission.

Consequence for the UI: a project bound to Command already has the GitHub path;
the tracker binding offers only Linear and Notion.

### 2. Tokens: `TokenCipher`, and how is the transport shown?

Yes, stored exactly like `commandToken`: `AppSettings` gains `linearToken` and
`notionToken`, sealed at the `SettingsRepository` boundary (`TokenCipher.seal`,
`enc:v1:` prefix, `PlaintextTokenCipher` fallback), migrated by the same
`transform` pass that already walks `commandToken`, and shown with the same
keyring status line in Config. Neither is ever logged, exported in a backup or
synced (the Supabase sync carries metadata, not settings).

Transport differs from provider and Command endpoints in a way that helps:
**the host is fixed in code** (`https://api.linear.app/graphql`,
`https://api.notion.com/v1`), not free text. So there is no `usesInsecureTransport`
to compute and no `NO TLS` pill to raise; the client refuses a non-`https` URI at
construction, which is cheap *because* nothing is configurable. The Config line
instead reports what is true and is not obvious:

- **Linear:** a personal API key acts as the whole account across every team. It
  cannot be narrowed. Config says `FULL ACCOUNT ACCESS`, and the plan accepts the
  cost for a single-user app rather than building OAuth, which would need a
  redirect handler and a refresh path on five platforms.
- **Notion:** an internal integration sees only the pages and databases shared
  with it. Config says `SHARED PAGES ONLY`. Prefer this one when a choice exists.

A `CHECK` button, like Command's, calls `viewer` (Linear) or `users/me` (Notion):
a wrong token and a wrong binding must not look identical.

### 3. Which `RouteKind`, and what does an older build do?

One new value: **`RouteKind.tracker`**, with the provider in `target`
(`Linear · ENG-412`, `Notion · Capture inbox`) and a new optional
`RouteRecord.url` for the link out. One kind rather than `linear` and `notion`:
the enum answers "how did it leave the desk", an extra provider must not be an
extra enum value, and the older-build cost is paid once instead of per provider.

The compatibility cost is the one `RouteKind.command` already documents, stated
before it is discovered: `RouteKind.fromName` returns null, so **an older build
drops that one `RouteRecord`.** The capture survives and
`isProcessedByUser` still says it left the desk; only "where did it go" vanishes.
`url` is absent on every legacy row and omitted from the JSON when null, so
existing rows serialise byte for byte as before. `_closureKindFor` is an
exhaustive `switch`, so adding the kind breaks the build until it is mapped:
`tracker` maps to `ClosureKind.route` (filed somewhere, not executed), not
`handoff`, which means something is working on it.

Rejected: reusing `RouteKind.file` (a lie about where it went), and defaulting
unknown names to `file`, which the enum's own docstring forbids.

### 4. Delivery confirmation and a timeout without duplicates

**A delivery counts only when the reply carries the created object's identity.**
`2xx` with an unparseable body is a throw, the same as a transport error.

| | Confirmation | Idempotency |
| --- | --- | --- |
| Linear | `issueCreate` returns `success`, `issue { id identifier url }` | `IssueCreateInput.id` accepts a client UUID. Send one derived from `capture.id`. |
| Notion | `POST /pages` returns `id` and `url` | No idempotency key exists. Query the database for the capture id first. |

A timeout is **unknown, not failed**: the request may have landed. The router
treats it as not delivered (throws, leaves the capture open) and makes the retry
safe by looking before creating:

- **Linear.** Retry calls `issue(id:)` with the same derived UUID first. Found:
  return it as the delivery. Not found: `issueCreate` with that id, so a second
  create racing the first fails on the duplicate id instead of filing twice.
  *Assumption to verify in Slice 2 before it ships:* that a duplicate `id` is
  rejected rather than silently creating. If it is not, fall back to Notion's
  query-first approach.
- **Notion.** Binding requires a `Capture ID` text property on the target
  database (the binding check reads the schema and refuses without it). Delivery
  queries `Capture ID == capture.id` first and returns the existing page's url if
  found, otherwise creates with the property set. There is a small window — a
  query issued before a still-in-flight create is indexed — in which a double
  tap-and-retry can produce two pages. It is accepted and bounded: the controller
  single-flights a route per capture id (in memory, like `_enrichingIds`), and
  both pages carry the same `Capture ID`, so the duplicate is visible and
  deletable rather than silent.

The record's `at` is stamped after the reply, as `CommandRouter` does, so it
cannot claim a time before the exchange that produced it.

## Design

```
RecordingsController.route(id)
        │
        ▼
   ProjectCaptureRouter          one decision point, unchanged callers
        ├── CommandRouter        bound Command + agentTask   (today)
        ├── TrackerRouter        bound tracker + trackerCategories   (new)
        └── ProjectInboxRouter   everything else            (today)
```

`TrackerRouter` is one `CaptureRouter` over a small
`TrackerClient` seam, so Linear and Notion do not each reimplement the order:

```dart
abstract interface class TrackerClient {
  bool get isConfigured;                       // synchronous, from settings
  String get label;                            // 'Linear' | 'Notion'
  Future<TrackerItem?> find(String captureId); // null = not there
  Future<TrackerItem> create(TrackerDraft draft, {required String captureId});
}
```

`TrackerItem` is `{ref, url}` (`ENG-412` or the page title, plus the link).
`DisabledTrackerClient` answers `isConfigured == false` and throws
`TrackerNotConfiguredException` at use, never at wiring time, so an unconfigured
install captures exactly as before. Real implementations:
`LinearTrackerClient`, `NotionTrackerClient`, in `lib/features/tracker/data/`.

`TrackerRouter.route` is: resolve the project binding → `find` → if found,
return its record → build the draft → `create` → return the `RouteRecord`.
`find` comes **before** drafting, so a retry of a delivered capture never spends
a model call.

**Binding.** `Project` gains one optional `tracker` object
(`kind`, `target` id, `label`, `boundAt`), absent-tolerant in `fromJson` and
omitted when null, so an unbound project serialises as today. It is chosen by
pickers over live reads (Linear teams; Notion databases visible to the
integration), never typed: a typed id is a third source of truth with no
validation, the drift the Command binding already avoids. A project may bind one
tracker; Command binding is independent.

**Selection.** `canRoute` stays synchronous and answers from configuration, never
the network. `ProjectCaptureRouter` keeps its order: bound Command + `agentTask`
goes to Command first. A tracker takes `task` and `agentTask` (when no Command is
bound), and Notion additionally `idea`, `meetingNote`, `researchLead`. A **null
category goes to the inbox**: null means enrichment never ran, which is not a
decision to file anything. The set is a constructor parameter, as
`commandCategories` already is.

### The agent-formatted body

The issue is title, context and acceptance criteria, in that order, built from the
`RoutedCapture` (title, summary, tags, transcript) and the project's description.

**The prompt lives next to the one it parallels.** A new
`lib/features/enrichment/domain/issue_draft_prompt.dart` exports
`buildIssueDraftSystemPrompt({EnrichmentContext context})`, beside
`buildEnrichmentSystemPrompt` in `enrichment_prompt.dart`. It reuses
`EnrichmentContext` (the user's soul and the project description) as *reference,
never instructions*, with the same head-and-tail truncation of a long transcript.
It is a **separate seam**, `IssueDraftService` (interface, `DisabledIssueDraftService`,
one HTTP implementation sharing `http_chat_enrichment_service.dart`'s transport),
because `EnrichmentService.enrich` returns the fixed `EnrichmentResult` shape and
widening it would put this into every enrichment pass.

**Not configured, or the model call fails: the delivery still happens.** The
draft is a quality step, not a gate. `TrackerDraft.fallback(capture)` builds
deterministically: the title is `capture.title`; the body is the summary, then the
transcript verbatim, then `## Acceptance criteria` containing the single line
`Not drafted — enrichment is not configured.` The line is written rather than the
section omitted: an empty acceptance list would read as "none needed". A model
failure takes the same path and the failure is logged, never thrown. A draft
failing must never be what leaves a capture on the desk.

The draft is regenerated on a retry that finds nothing; it is not persisted.
Idempotency is keyed on the capture id, not the content, so two different drafts
of one capture still resolve to one tracker object.

## Slices

Each ships alone and leaves the app working with no tracker configured.

### Slice 0 — `RouteKind.tracker` and `RouteRecord.url`

Compatibility first, with no destination behind it. Enum value, optional `url`,
`_closureKindFor` mapping, doc comment stating the older-build cost.
Tests (extend `test/route_record_test.dart`): round trip with and without `url`;
a legacy row has no `url` key and parses; an unknown kind still drops one row, not
the list; `tracker` closes as `ClosureKind.route`.

### Slice 1 — the seam, the draft and the fallback

`TrackerClient`, `DisabledTrackerClient`, `TrackerDraft`, `IssueDraftService`,
`DisabledIssueDraftService`, `issue_draft_prompt.dart`. No HTTP to a tracker.
Tests: fallback body names the missing acceptance criteria; a failing fake
draft service still yields a draft; prompt includes context as reference and
truncates a 90-minute transcript; the disabled client throws at use, not at
construction.

### Slice 2 — Linear

`LinearTrackerClient`, `linearToken` in `AppSettings` and the sealing pass,
Config section with `CHECK`, team picker and project binding.
Tests, against a fake HTTP layer only (no socket): `issueCreate` without
`issue.url` throws; timeout leaves the capture open and records nothing; a retry
finds the existing issue and sends no create; the derived UUID is stable per
capture id; token is stored sealed and `settings.json` holds no plaintext;
unbound projects serialise unchanged. Gate: confirm the duplicate-id behaviour
named above before merging.

### Slice 3 — `TrackerRouter` and selection

`TrackerRouter`, the `ProjectCaptureRouter` branch, `url` shown on the card as a
link. Tests: `canRoute` never touches the network; `find` precedes the draft
(draft service not called on a hit); null category goes to the inbox; a bound
Command + `agentTask` still goes to Command; a failed delivery leaves
`isProcessedByUser` false.

### Slice 4 — Notion

`NotionTrackerClient`, `notionToken`, database picker, the `Capture ID` property
check at binding. Tests: binding refuses a database without the property;
`find` hit returns the page and sends no create; a `2xx` with no `url` throws;
the Notion body maps the draft into blocks without truncating the transcript.

## Files

New: `lib/features/tracker/{domain,data}/`,
`lib/features/enrichment/domain/issue_draft_prompt.dart`,
`lib/features/settings/presentation/tracker_section.dart`.

Changed: `lib/features/recordings/domain/route_record.dart`,
`lib/features/recordings/data/` (the `ProjectCaptureRouter` branch),
`lib/features/recordings/presentation/recordings_controller.dart`
(`_closureKindFor` only), `lib/features/projects/domain/project.dart`,
`lib/features/settings/domain/app_settings.dart`,
`lib/features/settings/data/settings_repository.dart`, the card's status line,
`docs/architecture/agent-handoff.md`, `README.md`.

Untouched: the capture path, the processor registry, `NoteVault`,
`revisions.jsonl`, backup and sync formats.

## Not in scope

- **A GitHub Issues destination, or any GitHub token.** Command is the path.
- **Reading state back** (issue closed, status changed). `RouteOutcome` is
  Command-shaped (`CommandState`); a tracker outcome is a later plan, and the
  link out is what ships now.
- **OAuth** for Linear or Notion. A pasted key behind `TokenCipher` is enough
  for one user.
- **Editing or updating an existing issue** after delivery. Routing twice
  appends a second record, as it does for every destination.
- **Attachments.** The audio stays on the device; the transcript travels.

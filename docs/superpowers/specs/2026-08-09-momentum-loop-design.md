# Momentum: rewarding the closing of the loop

Status: **proposed** · Owner: laugustyniak · Scope: a durable record of what the
user *finished*, a daily target derived from their own pace, and the minimum
amount of movement and sound needed to make finishing feel like something.

## Why this exists, and what it deliberately refuses to do

The queue is easy to fill and hard to drain. Capture is already frictionless —
a hotkey, a sheet, a picked file — while the work that makes a capture worth
anything (reading it, routing it, handing it to an agent) has no feedback at
all beyond a row quietly leaving a list. Everything the app measures today is
either machine state (`RecordingStatus`) or an instantaneous fact
(`isProcessedByUser`); nothing anywhere answers *"how much did I actually get
through this week"*.

This adds that answer, and attaches the app's only celebratory moment to it.

**The reward hangs on closing the loop, never on opening it**, and that choice
is the whole design rather than a detail of it:

- Rewarding capture volume is a textbook Goodhart failure. The metric would be
  trivially farmable — a three-second recording at 23:58 satisfies it — and the
  farmed captures land in the queue the user then has to drain, so the feature
  would actively work against the thing it claims to encourage.
- Rewarding closures cannot be farmed without first capturing something real
  and then dealing with it. The cheapest way to move the number is to do the
  work.
- Closing an open loop is a *genuine* relief (an open item occupies working
  memory), so amplifying it is emphasis, not manufacture. This is what
  separates a loop that still works in month six from one that is filtered out
  in week three.

**Explicitly out of scope, permanently:**

| Not building | Why |
| --- | --- |
| Streaks that reset to zero | They work through loss aversion, and produce junk actions to protect them. Replaced by pace: a bad week lowers it, nothing zeroes it. |
| Badges, levels, trophies | They carry no information the adjacent number does not. A reward with no content habituates; a reward that says something different each time does not. |
| Re-engagement notifications | An offline-first app that nags is an app that gets uninstalled. |
| Any points for capture | See Goodhart above. This is the one hard prohibition. |
| Leaderboards, comparisons | Single-user app. There is nobody to compare to. |
| Any message on a bad day | See "The card is silent both ways" below. |

## Architecture

A new feature, `lib/features/momentum/`, in the house `domain/data/presentation`
layout. It is its own feature rather than an addition to `recordings` because it
reads from **two** sources and owns a store neither of them owns.

```
momentum/
  domain/
    closure_event.dart      ClosureEvent, ClosureKind, ClosureLog, NoopClosureLog
    momentum_snapshot.dart  DayClosures, paceOf, targetFrom, MomentumSnapshot
    cue_player.dart         Cue, CuePlayer, NoopCuePlayer
  data/
    file_closure_log.dart   FileClosureLog  (closures.jsonl)
    asset_cue_player.dart   AssetCuePlayer  (own AudioPlayer)
  presentation/
    momentum_controller.dart
    momentum_panel.dart     the Timer-tab panel
    day_closed_card.dart    the once-a-day card above the queue
```

### The store: `closures.jsonl`

The third append-only file in the repo, in exactly the shape of
`revisions.jsonl` and `focus-sessions.jsonl`.

```dart
enum ClosureKind { review, route, handoff }

class ClosureEvent {
  final String recordingId;
  final DateTime at;           // local; the day is counted from this instant
  final ClosureKind kind;
  final String? projectId;
  final String? projectName;   // denormalised, like FocusSession
  final CaptureType type;
}
```

**Why a separate file rather than counting from `recordings.json`.** That index
is rewritten wholesale and *shrinks* on `deleteRecording`. Deriving history from
it means deleting a capture silently rewrites the past — the exact failure class
`revisions.jsonl` exists to prevent: a file whose job is preserving facts must
not be overwritable. Separately, `recordings.json` holds *state*: one
`isProcessedByUser` bit cannot answer "how many did I close on Tuesday" no
matter how it is read.

`load()` follows `FocusSessionLog`'s contract exactly: a row that will not parse
is skipped and costs one event, never the file — a torn final line after a kill
mid-append must not be able to erase a month.

`ClosureKind.fromName(unknown)` returns **null and the row is dropped**, like
`RouteKind.fromName` and unlike `CaptureType.fromName`. There is no sensible
kind to assume, and a newer build's kind counted as `review` would be a quiet
lie about how the work left the desk. Only that row is lost.

### One closure per capture, forever

A `ClosureEvent` is appended **only on a given `recordingId`'s first transition
into the closed state**. Un-ticking and re-ticking produces nothing; routing the
same capture twice produces nothing the second time.

Enforced by a `Set<String>` of known ids, populated from `load()` and added to
on every append — the same in-memory-transient shape as `_enrichingIds` and
`_postersInFlight`.

**There is no single existing call site, and that is the trap.** Three paths
set `isProcessedByUser` today — `toggleProcessed`, `route` and the agent
handoff, the latter two because closing the item is the *consequence* of
delivering it rather than a second chore. Appending at each of them would count
one routed capture twice and leave the fourth path, whenever it is added,
silently uncounted.

So the diff moves into `_update`, the funnel every mutation already passes
through, beside `_recordRevisions`:

```dart
Future<void> _update(
  String id,
  Recording Function(Recording) change, {
  RevisionSource source = RevisionSource.processor,
  ClosureKind closure = ClosureKind.review,   // new
}) async { … }
```

When the diff shows `false → true` on `isProcessedByUser` and the id is not
already known, one event is appended with the caller's `kind`. `route` and the
handoff pass theirs; everything else gets the default.

This is the same argument that put revision recording inside `_update`: a
funnel cannot be bypassed by adding a new setter later. An optional parameter is
safe here in a way it would not be on `saveAll` — `_update` is private to the
controller, so no test fake overrides it and none can silently stop matching.

Note the deliberate asymmetry with `Recording.routes`, which *does* append on a
second delivery: two deliveries genuinely happened and the record says so. The
closure count answers a different question — how many things left the desk —
and one capture leaves it once.

### Best-effort, in-memory first

Under the `ClipboardSink` contract, and in the same order the revision history
uses: update the in-memory view, then append, swallow any error into `LogSink`.
A failed write leaves the count correct for the session and merely incomplete on
disk, rather than wrong in both places. It never throws into a close.

### The daily target, derived from the user's own pace

```dart
/// Median closures across *active* days within the last 14 calendar days.
double paceOf(List<ClosureEvent> events, DateTime now);

/// max(1, floor(pace)); 1 while fewer than 3 active days exist.
int targetFrom(double pace, int activeDays);
```

**Active days, not calendar days.** A weekend or a week off must not drag the
median to zero, because a target of zero is a target that cannot be missed and
therefore says nothing.

**The floor of 1 is load-bearing, not a guard.** A fresh install and a return
after a fortnight both meet a target of 1 — a guaranteed win on the first day
back, rather than the target of 5 that was current when the user fell off. This
is the endowed-progress effect: a card with two stamps already on it gets
completed more often than an empty one.

**Derived on read, never stored.** A running app crosses midnight; a persisted
"today's target" would be yesterday's by morning with nothing to correct it.
Same rule as `FocusTimerController.today`.

`DayClosures {day, closures}` is the per-day tally the panel and the card both
render, produced by a `tallyByDay` of the same shape as the timer's — days with
no closures are **not** invented here, and a caller wanting an unbroken strip
fills the gaps where it knows how many days it means to show.
`MomentumSnapshot` is what the controller exposes in one read: today's count,
the target, the pace and its direction, and the window of `DayClosures`.

### Reading focus sessions without reading the file twice

`MomentumController` takes a callback seam:

```dart
typedef FocusSessionsReader = List<FocusSession> Function();
```

The shell supplies `() => timer.sessions`. Same shape as `FocusProjectResolver`
and `EnrichmentContextSource`: no second read of `focus-sessions.jsonl`, a
session that just finished is visible immediately, and the dependency is on the
`FocusSession` type alone.

**`momentum` never writes to `focus-sessions.jsonl`.** `_record()` being called
from `_finish()` and nowhere else is the single reason "a pomodoro" means
exactly one thing, and a second writer would end that.

### Calendar arithmetic is reused, not moved

`focusDayOf` and `columnsFor` stay in `timer/domain/focus_session.dart` and are
imported. An earlier draft of this design moved them to a shared location;
importing is strictly better, because `momentum` already depends on that
library for `FocusSession` itself, so the move buys no decoupling and edits a
working file for nothing.

Reimplementing them is the one thing that must not happen. `columnsFor` is pure
integer arithmetic *specifically* because deriving column counts from
`last.difference(start).inDays` truncates an hour away across a DST transition
and drops a whole column — in Europe/Warsaw that silently removed *today's*
cell on five Mondays a year.

## Presentation

Four surfaces, each with one job.

| Surface | Shows | When |
| --- | --- | --- |
| Queue row | confirmation of the action | ~320 ms, on every close |
| Queue header counter | `DESK` count | on every change |
| `MOMENTUM` panel (Timer tab) | full history | always |
| `DAY CLOSED` card (top of queue) | target reached | once a day, dismissible |

**The Queue stays a place to work.** `CompactQueueHeader` exists precisely to
reclaim roughly a third of a phone screen before the first capture is drawn; a
permanent statistics panel there would undo that work. Everything durable lives
in the Timer tab, which is already the "how am I doing" destination — it has
`COMPLETED SESSIONS` with a heatmap, 7/30-day windows and a project split.
Momentum is the same view from the other side: sessions say how long the user
worked, closures say how much came out of it. A seventh navigation destination
was rejected — there are already six, in two layouts.

### 1. In-row micro feedback — 320 ms

The row fades (`opacity 1→0`) and translates 12 px right, `Curves.easeOutCubic`.

**The implementation hazard, named up front:** with the `DESK` review filter
active, a closed capture stops matching the filter immediately and vanishes with
no animation at all — the work simply evaporates. `_QueueTabState` therefore
holds `_closingIds`, and `_matchesReview` treats those as still visible for the
duration of the animation. Transient, presentational, and in the widget rather
than the controller because nothing about it survives a rebuild of the app, let
alone a restart.

The timer **must** be cancelled in `dispose()` or the binding reports a leak.

### 2. The counter moves

`ReviewedStrip` already animates its progress bar through
`TweenAnimationBuilder`; the same treatment goes on the number (400 ms) plus a
brief accent flash. Likewise for the counts inside `CompactQueueHeader`'s
segmented control.

### 3. The `DAY CLOSED` card

```
┌────────────────────────────────────────────┐
│ DAY CLOSED                              ✕  │
│                                            │
│ 4 closed · target 3                     ✓  │
│ pace 3.2/day  ↑ from 2.8                   │
│                                            │
│ ■ ■ □ ■ ■ ■ ■   last 7 days                │
└────────────────────────────────────────────┘
```

A plain `ConsoleCard` sliding in above `ReviewedStrip` (`AnimatedSize`, 220 ms).
Not a modal, not an overlay, not a snackbar — the app has none of those, and
reserves dialogs for destructive confirmation only. One line on a compact
layout, expandable.

Dismissed by ✕, and **not restored after a restart**: one card per day, held in
memory. `DESK CLEAR` replaces the heading on the rare day the queue empties,
with "first time in N days" as the second line — the variable, informational
payload that keeps the moment from habituating.

**The card is silent both ways.** It never appears on a day below target. Its
absence is the absence of a message, not a verdict. An app that comments on the
user's empty days teaches avoidance exactly when returning matters most.

### 4. The `MOMENTUM` panel

Directly above `COMPLETED SESSIONS`, in the identical layout (34 px display
figure, window chips, chart) so the two read as two measures of one rhythm.

```
┌────────────────────────────────────────────┐
│  4  closed today                 target 3 ✓│
│                                            │
│  [7 DAYS]  [30 DAYS]              23 in 7  │
│                                            │
│  mon ████████ 5                            │
│  ...                                       │
│                                            │
│  CLOSED BY PROJECT                         │
│  augustyniak-capture  ████████████ 12      │
│  audivoa-core         ██████ 7             │
│  no project           ███ 4                │
└────────────────────────────────────────────┘
```

`CLOSED BY PROJECT`, **not** `WHERE IT WENT` — the Timer tab already carries a
section under that heading for the session split, and two identical headings
describing different things on one screen is a genuine ambiguity, the same one
that makes the review filter's third chip read `ANY` rather than `ALL`.

The project split reuses `tallyByProject`'s two ordering rules: unattributed
time always sorts last (it is the residual, not a competitor), and an equal
count breaks on volume before name so the order cannot flicker.

**Three states, not two**, exactly like `_FocusHistory`: data, "nothing closed
yet", and `closuresUnreadable`. The third is not a formality — "you have closed
nothing" is a positive claim about the user's history and must not be made when
the file merely failed to read. Same rule as `_indexUnreadable` and
`historyUnreadable`.

### 5. Sound

A seam in the shape of `AlarmPlayer`: `CuePlayer` in `domain/` (so the pure-Dart
suite can assert *which* cue was requested with no audio device present),
`NoopCuePlayer` as the default, `AssetCuePlayer` in `data/` over **its own**
`AudioPlayer` — never the recordings controller's, for the reason the alarm has
its own: a close confirmation must not stop a clip being reviewed.

Two vendored clips, generated with ffmpeg like the existing three — decaying
sines, mono 22.05 kHz:

- `assets/sounds/close.wav` — one tone, ~80 ms
- `assets/sounds/day.wav` — two tones, falling interval, ~260 ms

**Peaked at −18 dBFS, not the alarms' −3.** An alarm exists to pull the user out
of work; a confirmation exists to be barely noticed. A cue that makes someone
flinch on every tap gets muted within a week — and it is the system volume that
gets muted, taking the session alarm with it.

Config key `cueSounds` in `settings.json`, **absent while untouched** — the
three-state private-nullable pattern `shortcuts` and `enrichmentInstructions`
use — so a later build can still ship a better default to everyone who never
chose. Ships on.

## Testing

Beyond the usual round-trip and legacy-defaults tests for `ClosureEvent`:

1. **No animation may repeat.** CLAUDE.md keeps a list of widgets that hang
   `pumpAndSettle` forever (`PulseDot`, `ScanLine`, a focused `TextField`, a
   running `CountdownDial`). Neither the counter flash nor the card slide may
   join it: one-shot `TweenAnimationBuilder`, no `repeat()`.
2. **The clock is a constructor seam** (`DateTime Function()`), as in
   `FocusTimerController`. The target reads the last 14 days, so a test must be
   able to substitute a date rather than wait for one. No test in this suite
   may sleep for a fixed span — see `_until` in `recording_limit_test.dart`.
3. **A DST sweep over the target and the calendar grid.** Calendar arithmetic
   (`DateTime(y, m, d ± n)`), never `Duration`. This trap has already cost this
   repo today's column five times a year.
4. **One closure per capture**: close, re-open, close again → exactly one event.
5. **Routing counts once**: `route()` sets the flag itself, so a routed capture
   must produce one event of kind `route`, not one `route` plus one `review`.
6. **`closuresUnreadable` is distinct from empty** — a log that throws on load
   must not render "nothing closed yet".
7. **The `_closingIds` timer is cancelled on dispose**, asserted by closing a
   row and immediately tearing the widget down.

Everything except the widget-level animation tests is pure Dart. `ClosureLog`
and `CuePlayer` are interfaces in `domain/` for exactly that reason.

## What this touches in existing code

Deliberately minimal — one field on one persisted type, and no change to
`Recording` at all:

| File | Change |
| --- | --- |
| `settings/domain/app_settings.dart` | `cueSounds`, private-nullable |
| `recordings/presentation/recordings_controller.dart` | a `closure` parameter on `_update` and the append beside `_recordRevisions`; `kind` passed by `route` and the handoff; optional `ClosureLog` + `CuePlayer` seams, defaulting to the no-ops |
| `recordings/presentation/queue_tab.dart` | `_closingIds`, the `DAY CLOSED` card slot |
| `recordings/presentation/queue_metrics.dart` | animate the counter |
| `recordings/presentation/compact_queue_header.dart` | animate the segment counts |
| `timer/presentation/timer_tab.dart` | mount `MomentumPanel` above `COMPLETED SESSIONS` |
| `settings/presentation/config_tab.dart` | the `cueSounds` toggle |
| `recordings/presentation/recordings_page.dart` | own `MomentumController`, wire the reader callback |

That a feature about progress needs no new value on `RecordingStatus` and no new
field on `Recording` is the strongest evidence it is cut in the right place. A
version of this that had to touch either would be one that had misidentified
what it was measuring.

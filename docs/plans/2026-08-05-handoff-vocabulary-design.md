# Hand-off Vocabulary

## Outcome

The review axis stops borrowing the language of email. A capture sits on the
user's **desk** until they decide who executes it, and leaves once it has been
**handed off**. `Inbox zero` — the one string in the app that named a Google
product's goal state — is gone, along with the register it dragged in.

Nothing on disk changes. `isProcessedByUser`, `processedAt`, `RouteKind`,
`RouteRecord` and `recordings.json` are untouched, as are `pubspec.yaml`, the
platform display names and `test/rebrand_test.dart`. The product is still
**Augustyniak Capture** and the identifier is still `ai.augustyniak.capture`.

## Why the mail metaphor was wrong here

Not only by association. The two frames describe opposite motions.

An inbox holds **what the world puts on you**; you are the executor, and zero is
compliance with an obligation someone else created. This queue only ever holds
**your own thoughts**, dictated away from the keyboard, and the question each
row asks is *who does this — me or an agent*. That is delegation, and the arrow
points outward.

The frame was already in the domain model; only the UI lagged behind:

| Where | What it already says |
| --- | --- |
| `route_record.dart` | `RouteKind.agent` — "Handed to a coding agent as the opening prompt of a session." |
| `enrichment_defaults.dart` | "Route by what I must DO next"; the `task` / `agentTask` split is "do I do this, or does an agent". |
| `capture_category.dart` | Categories are "routing destinations, not topics". |

`README.md` also contradicted the code: it promised *no "Inbox Zero"
celebration or empty-inbox pressure* while `queue_tab.dart` rendered exactly
that string.

## Vocabulary

| Surface | Before | After |
| --- | --- | --- |
| Review filter enum | `ReviewFilter { inbox, done, all }` | `ReviewFilter { desk, handedOff, all }` |
| Review chips | `INBOX 4 · DONE 33 · ANY 37` | `DESK 4 · OFF DESK 33 · ANY 37` |
| Rail progress strip | `DONE 33 / 36 · 92%` | `CLEAR 33 / 36 · 92%` |
| Empty panel, desk filter | `Inbox zero — everything is closed.` | `Desk clear — it's all with someone.` |
| Empty panel, other side | `Nothing closed yet.` | `Nothing handed off yet.` |
| Route control | `Send to the project's inbox and close` | `Hand off to the project's inbox` |
| Semantics on both strips | `Done n of m captures` | `Handed off n of m captures` |

### Three lengths of one image, and why they differ

The label is not the same word everywhere, and that is a measurement rather
than a preference. Both shortenings were forced by a widget that overflowed.

- **Chips get `OFF DESK`, not `HANDED OFF`.** On a phone this row *is* the
  progress metric — `nav_rail.dart` notes the compact layout no longer spends a
  queue row on a strip — so the three chips have to share one line with the
  `n / m`. The longer label pushes the `Wrap` onto a second line and takes back
  the row that was saved.
- **The rail gets `CLEAR`, not `OFF DESK`.** That strip also carries the
  percentage, and at `ConsoleText.micro`'s letter spacing `OFF DESK 34 / 35`
  beside `97%` overflows the 184 px the 216 px rail leaves by **21 px**.
- **The empty panel spells it out in full** — it has a whole line and is the
  one place the metaphor has to land unaided.

### Hand off, not delegate

`DELEGATE` was considered and rejected. Delegation implies accountability: you
expect the work back. `RouteRecord` states *where* a capture went and *when*,
and nothing returns — there is no outcome field and no return path. `Hand off`
promises delivery only, which is what the code actually does.

If a return path is ever built, `RouteRecord` grows a result and `handedOff`
stops being terminal. That is a real feature with a second state axis to
reconcile against `RecordingStatus`, not a rename.

## Side effect: `DONE` stops meaning two things

`DONE` was both the review chip ("this capture is off my desk") and the inline
editor's exit button ("I am finished typing"). `recording_editor.dart` explains
at length why that button says `DONE` rather than `SAVE` — every field
auto-saves — so the collision was resolved by moving the review axis, leaving
the editor's label alone.

## Files

`queue_tab.dart`, `queue_metrics.dart`, `nav_rail.dart`, `recording_card.dart`,
`README.md`, and the string assertions in `test/widget/queue_tab_test.dart` and
`test/widget/nav_rail_test.dart`.

## Not in scope

- Renaming the product or the application identifier. The identifier is
  immutable per `CLAUDE.md`; a change republishes the app and strands every
  install's recordings under the old container.
- Renaming `isProcessedByUser`. It is persisted, its meaning is unchanged, and
  a JSON key rename would buy nothing but a compatibility branch.

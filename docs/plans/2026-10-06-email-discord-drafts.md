# Plan: draft an email or a Discord message from a capture

Status: **proposed** · Owner: laugustyniak · Scope: a capture that is really a
message ("tell Anna the invoice moves to Friday") gets a model-written draft the
user edits and then hands to their own mail client or to Discord. Nothing is ever
sent by this app without a user action on the finished text. Refs #255.

> Sibling plan: `docs/plans/2026-10-06-send-to-any-assistant.md` (#244) adds a
> **Send to…** sheet with copy, `share_plus` and web destinations. This plan does
> not build a second sheet. It adds two destinations to that one and reuses its
> plumbing; see "Relation to #244".

## Motivation

A capture filed as a message to someone ends up as what it was dictated as: a
rambling transcript addressed to nobody. The user rewrites it by hand into three
polite sentences, which is exactly the chore the enrichment stage already does
for titles and summaries. The queue has no destination for it either:
`CaptureRouter` writes to a project's `inbox.md`, and `AgentHandoff` opens a
coding agent. A message is neither a file nor a task.

The risk is the opposite of the usual one. A model that drafts and a button that
sends is one misheard name away from a wrong email to a client. So the design is
built around the draft being **text the user reads and sends themselves**, through
a channel they already trust.

## What does not change

- **Persist before process.** Drafting runs on a capture that is already saved
  `completed`, on an explicit tap, minutes or days later. Nothing here runs in
  `stopRecording()`, `addTextNote()` or the drain loop, and `Recording.status` is
  never touched by it.
- **Nothing is sent without an explicit action.** No background drafting, no
  auto-send, no rule such as "category `message` sends on completion". Generation
  is a button; delivery is a second button on the reviewed text.
- **Best-effort, and unconfigured means absent.** The drafter uses the enrichment
  profile. With none configured the button is hidden, like the agent button on an
  install with no launcher, and capture is unaffected.
- **Delivery first, state second.** The `CaptureRouter` contract holds: a
  delivery that throws records nothing and closes nothing.
- **`recordings.json` stays backward compatible.** One optional field is added to
  `Recording`; the key is omitted while null, so an untouched row serialises byte
  for byte as before.
- **No contacts permission, no mail account, no OAuth.** Slice 1 needs none of
  them.

## Design

### Email: `mailto:` first, because it costs nothing

| Option | Token / setup cost | Verdict |
| --- | --- | --- |
| `mailto:` via `url_launcher` | None. The OS opens the user's default client with To, Subject and Body prefilled. | **Slice 1** |
| Gmail drafts API | OAuth client, a Google consent screen, a refresh token to store and a restricted scope (`gmail.compose`) with verification overhead. Gmail-only. | Rejected for now |
| Share sheet (`share_plus`) | None, but it shares text with no To or Subject, and on desktop Linux and Windows it is weak or absent. | Fallback only |

`mailto:` wins on the app's own terms: no new secret to hold (`CLAUDE.md` forbids
a provider-wide key in the app and the keyring story is already heavy), no network
beyond the model call, and it works with any client. `url_launcher` is already a
dependency (`lib/app/version_footer.dart`, `lib/app/markdown_view.dart`).

Its limits are real and are stated here rather than discovered:

- **`mailto:` cannot confirm anything.** The OS reports that a handler was
  launched, not that a message was sent or even composed. See "What delivered
  means".
- **Length.** Long bodies are truncated or rejected by some clients and by
  Windows' `ShellExecute`. The builder percent-encodes with `%0D%0A` newlines and,
  above a budget (2000 characters of encoded URL), launches with To and Subject
  only, puts the body on the clipboard and says so on the sheet. It never
  truncates silently: a draft cut mid-sentence looks finished.
- **Gmail-draft API stays an upgrade path, not a plan.** If it is ever built it
  is one more `DraftDelivery` behind the same seam and its token is a
  `TokenCipher`-sealed setting. Nothing in slice 1 forecloses it.

### Discord: copy plus deep link first, webhook second

Discord has no draft object. Options:

| Option | Behaviour | Verdict |
| --- | --- | --- |
| Copy + deep link | Text to the clipboard, then open `discord://` (or the channel URL) so the user pastes and presses Enter. | **Slice 2** |
| Webhook per channel, confirm-to-send | The app POSTs `{content}` to a channel webhook after a confirm step. | **Slice 3, opt-in** |

Copy plus deep link is the default because the user's own Discord client is the
final confirm step, mentions resolve there (`@name` is client-side, a webhook
cannot resolve it), and no secret is stored. Its cost is that the user pastes.

A webhook posts **as a bot into one channel**, not as the user, and it is a bearer
secret: anyone with the URL can post. It is therefore opt-in per destination and
held to the existing token rules:

- stored through `TokenCipher` (`enc:v1:` on disk), with a usable-accessor that
  keeps an undecryptable blob out of the request, on the model of
  `AppSettings.usableCommandToken`; the webhook name is readable, the URL is not;
- the Config tab shows the same keyring status line as other secrets;
- **confirm-to-send is a sheet showing the exact text and the channel name**, with
  a button labelled `POST TO #channel`. There is no send-on-generate and no
  "do not ask again";
- the URL is validated as `https://discord.com/api/webhooks/<id>/<token>` (and the
  `discordapp.com` host) before it is stored, so a typo cannot turn this into a
  generic POST-anywhere client;
- the response is checked: 2xx records a route; anything else throws and leaves
  the capture open.

### Recipients without a contacts permission

The app never reads the address book. Recipients come from three places, in
order:

1. **What the capture says.** Enrichment-style extraction returns `to` as a
   *hint string* ("Anna"), never an address. A bare name is shown in the sheet as
   unresolved text. The model is told not to invent addresses and the parser drops
   any value that does not look like one (`@` for email) rather than trusting it.
2. **A small recipients list in Config**, `MessageRecipient {label, email?,
   discordChannel?}`: user-typed, local, versioned like the project list. A
   hint matching a label case-insensitively preselects it; otherwise the field is
   a typed text box. It is a convenience list, not an address book, and it is
   included in backup and not in sync (it holds other people's addresses).
3. **The mail client itself.** With To left empty, `mailto:` still opens with
   subject and body, and the user's client autocompletes from its own contacts,
   which is the contacts access this app does not need.

An address never reaches the model: the draft prompt gets the capture text, the
profile and the *label*, not the resolved address.

### The draft is generated by the enrichment provider

`MessageDraftService` is a new seam shaped like `EnrichmentService`:
`DisabledMessageDraftService` default, `HttpChatMessageDraftService` over the same
OpenAI-compatible `/v1/chat/completions` call and the **same active enrichment
profile**, resolved per call rather than snapshotted, so a Models change affects
only drafts started afterwards. It differs from enrichment in three ways that
matter:

- It is **user-triggered, not pipeline-triggered**, so it is not best-effort in
  the swallow-everything sense: a failure surfaces on the sheet with the provider
  failure text and the capture is unchanged.
- It reuses the enrichment prompt's rules for untrusted input. The capture text is
  data inside a fence; the instruction is "write the message the speaker intends,
  in their language, no invented facts, no invented recipient, no signature the
  user did not dictate". The output is `{subject?, body}` JSON (`subject` only for
  email) parsed with the degrade rule: an unusable answer is an error, never an
  empty draft.
- Cost is recorded through `UsageSink`. This needs a `UsageStage.draft`;
  `UsageStage.fromName` returns null for an unknown name, so confirm in `costs.md`
  that an older build drops that usage row rather than failing the file.

When the profile is unconfigured, the Send-to rows for email and Discord still
appear if a *non-drafted* send is meaningful (open `mailto:` with the raw
transcript, or copy it) and show the draft row as `needs an enrichment profile`.
That keeps the destination usable offline and never fakes a draft.

### Where the draft is stored: a new field, not a revision, not a route record

- **Not a `RecordingRevision`.** Revisions are field-level records of what was
  *overwritten*, for five tracked fields, and a change out of an empty value is
  never recorded. A draft is new content, not a replaced value; routing it
  through `_update`'s diff would either record nothing or pollute HISTORY.
- **Not a `RouteRecord`.** A route is one delivery that happened, append-only. A
  draft exists before delivery, may never be delivered, and is edited many times;
  most drafts would be dead rows with a made-up `target`.
- **A new nullable `Recording.drafts: List<MessageDraft>?`.** Absent and empty are
  different facts, applied exactly as `segments` does:
  `null` (key omitted) means "never drafted"; a non-empty list means drafts exist;
  a draft with a blank body is never stored (a model that returned nothing is an
  error, not an empty draft), so there is no third state to explain.
  `MessageDraft {channel, to?, subject?, body, createdAt, editedAt?}` where
  `channel` is `email` or `discord` and an unknown channel name drops that one
  draft on load (`fromName` returns null), the `RouteKind` rule: guessing a channel
  could deliver to the wrong place.
- At most **one draft per channel** per capture. Regenerating replaces it, and
  the sheet asks first when `editedAt` is set, since a hand-edited draft is the one
  thing that is not recoverable. Draft edits are not revisioned; that is stated,
  not hidden, and a later slice can add a tracked field if it matters.
- Legacy compat: an old row has no key and loads `null`; a new row with `drafts`
  is read by an old build as an ignored unknown key (it is not in the old
  `fromJson`). The draft therefore rides `recordings.json` and the sync row's
  `payload`, and is dropped by builds that predate it without breaking the row.

### Relation to #244

#244 plans one **Send to…** sheet over `share_plus`, web destinations, a
clipboard path and a new `RouteKind.assistant`. This plan **does not add a second
sheet**; it contributes two rows to that one and consumes four things from it:

1. the sheet shell and its "record the route, do not close the capture" rule for
   channels that cannot confirm;
2. the clipboard-plus-open fallback used for over-long prompts, which is exactly
   the long-`mailto:` and Discord-copy path here;
3. the URL-opening seam (a `UrlOpener` interface with a disabled default so the
   pure-Dart suites never launch anything), which this plan needs for `mailto:`
   and `discord://`;
4. `share_plus` as the email fallback on mobile.

What is different is the payload. #244 sends the capture's own prompt to an
assistant; this sends a *generated message* to a person. So the rows live in the
sheet, but the draft editor is its own step opened from them. **Ordering:** slice
1 here depends on #244's sheet and `UrlOpener` landing first; if it has not, slice
1 ships its own `UrlOpener` in `lib/core/` and #244 adopts it, and the one
sheet-level change is a row. No `RouteKind` is duplicated: a single
`RouteKind.message` covers both channels here, with the channel in `target`
(`email · anna@…`, `discord · #ops`). Older builds drop that row, the same stated
cost as `command` and `assistant`.

### What "delivered" means per channel

`CaptureRouter.route` always closes the item. These destinations cannot all
honour that, so the controller gains one entry point that records a route and
**closes only when told to**, shared with #244's web path. The rule per channel:

| Channel | What the app knows | Records a route | Closes the capture |
| --- | --- | --- | --- |
| `mailto:` | A handler was launched. Not that mail was composed or sent. | Yes, `target: email · <to or "draft">` | **No.** The user closes it, as for #244's web path. |
| Email via share sheet | The sheet was shown. | Yes | No |
| Discord copy + deep link | Text on the clipboard, app opened. | Yes | **No** |
| Discord webhook | HTTP 2xx from Discord. | Yes, after the 2xx only | **Yes**, it is the one channel with a confirmation |

The card line for the unconfirmed channels reads `DRAFT OPENED`, not `SENT`; the
word `sent` appears only after a webhook 2xx. A failed webhook POST throws, records
nothing, closes nothing and keeps the draft, so a retry is one tap. Retrying a
webhook after a timeout can double-post (Discord has no idempotency key); the
sheet says so on the retry rather than hiding it, which is the honest version of
the idempotency promise the Command PUT can make and this cannot.

## Slices

Each ships alone and leaves the app working with no enrichment profile, no
recipients and no webhook.

### Slice 0 — the draft type and its storage, no UI

- New: `lib/features/recordings/domain/message_draft.dart`;
  `Recording.drafts` nullable with the key omitted when null.
- Tests: `test/message_draft_test.dart`: round trip; legacy JSON has no `drafts`
  key and loads null; null serialises without the key (byte-identical row);
  an unknown channel drops one draft, not the list; a blank body is refused;
  `recording_test.dart` round-trip extended.

### Slice 1 — email drafts via `mailto:`

- New: `lib/features/messages/{domain,data}/` with `MessageDraftService`
  (disabled default + HTTP implementation), `MailtoBuilder` (pure Dart),
  recipient hint parsing.
- Changed: the Send-to sheet row and a draft editor; `RecordingsController` gets
  `draftMessage(id, channel)` and the record-without-closing entry point;
  `RouteKind.message`; `UsageStage.draft`.
- Tests: `mailto_builder_test.dart` (percent-encoding, `%0D%0A`, non-ASCII, a `&`
  or `?` in the body cannot add a header, over-budget falls back to
  body-on-clipboard); `message_draft_service_test.dart` against a fake HTTP layer
  (usable JSON, blank body is an error, model-invented address dropped);
  `message_draft_controller_test.dart` (unconfigured hides the draft row; a
  throwing service leaves `drafts` null and the capture untouched; opening
  `mailto:` records a route and leaves `isProcessedByUser` false; regenerate over
  an edited draft requires confirmation).

### Slice 2 — Discord copy plus deep link

- Changed: Discord row; clipboard then `discord://` via the shared `UrlOpener`.
- Tests: clipboard is written before the URL is opened, and an opener failure
  still leaves the text on the clipboard; route recorded, capture not closed.

### Slice 3 — recipients list

- New: `MessageRecipient` and a Config section; hint-to-label matching.
- Tests: legacy settings without the list load empty; matching is
  case-insensitive; an unmatched hint is shown as text and never becomes an
  address; the list is in the backup archive and absent from the sync payload.

### Slice 4 — Discord webhook, opt-in

- New: sealed webhook URL on a destination, `usableWebhookUrl`, URL validation,
  the confirm sheet, `HttpDiscordWebhookClient`.
- Tests: a plaintext URL is sealed on save and never logged (the `LogSink` line
  carries the channel label only); a non-Discord host is refused; 204 records a
  route and closes; 4xx and 5xx throw, record nothing and keep the draft; an
  undecryptable blob disables the destination instead of sending without it.

## Files

New: `lib/features/messages/{domain,data}/`,
`lib/features/recordings/domain/message_draft.dart`,
`lib/features/messages/data/mailto_builder.dart`.

Changed: `lib/features/recordings/domain/recording.dart`,
`lib/features/recordings/domain/route_record.dart` (`RouteKind.message`),
`lib/features/recordings/presentation/recordings_controller.dart`
(`draftMessage`, record-without-closing), the #244 Send-to sheet,
`lib/features/costs/domain/usage_event.dart` (`UsageStage.draft`),
`lib/features/settings/` (recipients, webhook), `docs/architecture/` (a new
`messages.md` and a row in `CLAUDE.md`'s table).

Untouched: the capture path, the processor registry, `revisions.jsonl`, the
enrichment prompt and its field ownership, the note vault.

## Not in scope

- **Sending email from this app.** No SMTP, no Gmail send, no sending on the
  user's behalf. Drafts only.
- **Gmail drafts API.** Kept as a documented upgrade behind the same seam, not
  built here.
- **Reading contacts, a mailbox or a Discord server.** No address book, no
  channel discovery, no reading replies.
- **Auto-drafting by category.** `CaptureCategory` has no message value. Adding
  one is a separate decision: the enrichment prompt is generated from the enum, so
  it is cheap, but it would make the model's label decide whether a draft button
  appears, which this plan avoids by showing the row on any completed capture.
- **Other chat platforms** (Slack, Telegram, WhatsApp). The seam allows them; each
  has its own confirmation story.
- **A draft revision history.** Hand edits to a draft are not tracked.

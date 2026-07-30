# LLM enrichment: auto-title, categorize, summarize and tag

**Issue:** #21
**Status:** approved, ready for implementation

## Problem

Every completed item in the queue carries a wall of text — a transcript, an OCR
dump, or a note body — and nothing else. The card falls back to a filename, and
finding an item means reading through it. There is no signal about what an item
*is*, so nothing downstream can route it: a task, a durable note, and a
throwaway thought are indistinguishable to the app.

## Solution

After a processor produces text, send that text to a configurable
OpenAI-compatible chat model and ask for a structured verdict:

```json
{"title": "...", "category": "note", "summary": "...", "tags": ["...", "..."]}
```

The result is stored on the item. Nothing consumes `category` yet — that is a
later spec (see *Out of scope*).

## Category vocabulary

Categories are **routing destinations**, not topics. That constraint is what
keeps the list short enough for a small model to classify reliably.

| Category | Meaning | Eventual destination |
| --- | --- | --- |
| `note` | Durable knowledge or reference | Obsidian |
| `task` | Actionable by a human | Todoist |
| `agentTask` | A prompt or spec for an AI agent to execute | Agent queue |
| `idea` | Product or business idea, not yet actionable | Obsidian, separate folder |
| `meetingNote` | Attendees plus decisions | Obsidian, meeting template |
| `researchLead` | A paper, link or topic to chase | Reading queue |
| `capture` | Unclassified fallback | Stays in the queue |

`CaptureCategory.fromName(null | unknown)` returns `capture`, mirroring
`CaptureType.fromName`. A category written by a future build must never throw an
older one, and a model that invents a label must not fail the item.

Deliberately excluded: `reminder` (a `task` with a due date), `contact` and
`shopping` (too narrow — each is already a `task` or a `note`), and
`journal` / `question` / `draft` / `reference` (held back to keep the
vocabulary small until the real distribution is visible).

## Domain model

New file `lib/features/recordings/domain/capture_category.dart`:

```dart
enum CaptureCategory { note, task, agentTask, idea, meetingNote, researchLead, capture }
```

with a `label` per value (English — the design pass moved every UI string off Polish) and a static `fromName`.

`Recording` gains three persisted fields:

- `category` — `CaptureCategory?`. **Nullable on purpose:** `null` means "never
  enriched", `capture` means "the model looked and could not classify it". They
  are different states and collapsing them would make an un-configured install
  indistinguishable from a failing model.
- `summary` — `String?`
- `tags` — `List<String>`, defaults to `const []`

`title` is unchanged in shape. `copyWith` gains the three fields with the
existing `clear*` flag convention. `fromJson` defaults all three when absent, so
every row written before this change keeps loading.

## Enrichment feature

New `lib/features/enrichment/`, mirroring `features/transcription/`:

- `domain/enrichment_result.dart` — `EnrichmentResult {title, category, summary, tags}`,
  every field nullable/empty-able because a partial response is still useful.
- `domain/enrichment_service.dart` — the `EnrichmentService` interface plus
  `DisabledEnrichmentService`, which throws `EnrichmentNotConfiguredException`.
  Identical degrade-don't-crash shape to `DisabledTranscriptionService`: an
  unconfigured install produces items with no category rather than errors.
- `data/http_chat_enrichment_service.dart` — POSTs an OpenAI-compatible
  `/v1/chat/completions` body with `response_format: {"type": "json_object"}`, an
  optional bearer token and a configurable model.

Two rules to hold:

**The system prompt is generated from the enum.** The category list in the
prompt is built by iterating `CaptureCategory.values`, not hand-written. A
literal list desyncs from the code the first time a category is added, and the
failure is silent — the model simply never emits the new label.

**Input is truncated:** head 8000 chars + `\n[...]\n` + tail 4000 chars. A
90-minute transcript would otherwise cost more to enrich than it cost to
transcribe. Head-and-tail rather than head-only because the closing minutes of a
recording usually carry the conclusion.

Parsing is defensive. The response body is read from
`choices[0].message.content`, ```` ```json ```` fences are stripped, and then:
unknown or missing category → `capture`; blank title → `null`; tags trimmed,
lowercased, deduped, capped at 5; summary trimmed.

The split between "degrade" and "throw" is explicit: a body that **is** a JSON
object degrades field by field to a partial `EnrichmentResult`, while a body
that is not parseable JSON at all, or a non-2xx response, throws. Either way the
item survives — the caller treats enrichment as best-effort — but only the
second case produces a log entry worth reading.

## Pipeline placement

Inside `RecordingsController._drainProcessingQueue`, after the processor returns
its text:

1. `_update` the item to `completed` with its transcript — **persisted first**
2. `ClipboardSink` fires (unchanged)
3. *Then* enrichment runs; on success a second `_update` writes
   title/category/summary/tags

Enrichment sits after the completed-write, not before it, so a crash or a kill
mid-enrichment leaves a good completed item instead of one stuck in limbo. This
is the same reasoning as the capture pipeline's persist-before-process rule.

Skipped silently when the service is disabled or the text is blank. Every
failure is caught, logged through `LogSink`, and leaves the item untouched —
the `ClipboardSink` contract. `_disposed` is checked at the await boundary.

`enrichmentService` is a runtime-settable field like `transcriptionService`; a
swap from the Models tab affects only jobs started afterwards.

**The title is filled only when it is null or blank.** A user-set title is
permanent, and a retry must never overwrite it. This keeps the existing
invariant — "processing never overwrites a user title" — literally true rather
than qualified.

Enrichment runs for **every** capture type, text notes included. A note is where
an auto-title helps most.

## Settings

`ProviderProfile` gains `kind: ProfileKind {transcription, enrichment}`, with
`ProfileKind.fromName(null | unknown) → transcription` so every profile already
in `settings.json` keeps working untouched. `toService()` is unchanged; a new
`toEnrichmentService()` applies the same blank-or-schemeless-endpoint guard and
returns the disabled impl.

`AppSettings` gains `activeEnrichmentProfileId` and an `activeEnrichmentProfile`
getter that returns null for a dangling id. A second id rather than reusing the
first, because one profile of each kind must be active simultaneously.

New kind-tagged presets:

| Name | Endpoint | Model |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1/chat/completions` | `gpt-4o-mini` |
| Groq | `https://api.groq.com/openai/v1/chat/completions` | `llama-3.3-70b-versatile` |
| Lokalny Ollama | `http://localhost:11434/v1/chat/completions` | — |

The Models tab splits into two sections filtered off the one profile list by
`kind`; the add-profile sheet picks a kind first and filters presets to match.
`SettingsController` exposes `enrichmentService`, and the shell pushes it into
`RecordingsController` on every settings change exactly as it already does for
`transcriptionService`.

## UI

- `recording_card.dart` — a category `ConsoleChip` beside the status pill, and
  the summary as a dimmed line under the title. Both hidden when null, so an
  unenriched queue looks exactly as it does today.
- `edit_sheet.dart` — a category dropdown (editable), tags as read-only chips,
  summary read-only. Correcting a misclassification matters more than filtering
  by one: a wrong category poisons whatever export reads the field later.
- `RecordingsController.setCategory(id, category)` routes through `_update`,
  like `toggleProcessed`.
- No new snackbars or dialogs — inline feedback only, per the existing rule.
- The Queue filter row is untouched in this phase.

## Testing

Pure-Dart, no bindings:

- `CaptureCategory.fromName` — null and unknown both resolve to `capture`
- `Recording` JSON round-trip, plus a legacy row with no category/summary/tags
- `ProviderProfile` round-trip, plus a legacy row defaulting to
  `kind: transcription`
- Response parsing: fenced JSON, unknown category, more than 5 tags, blank
  title, malformed body
- `RecordingsController` against a fake enrichment service: fills a null title;
  **never** overwrites a user-set title; a throwing service leaves the item
  `completed`; a disabled service is a no-op; a blank transcript is skipped

## Out of scope

Nothing consumes `category` yet — no Obsidian write, no Todoist push, no agent
dispatch. This spec covers classification and storage only. Export is a separate
issue, and it is the reason the category must be user-correctable here.

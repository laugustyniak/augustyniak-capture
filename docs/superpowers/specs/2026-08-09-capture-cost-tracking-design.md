# Capture cost tracking — design

**Date:** 2026-08-09
**Status:** approved, not implemented

## Problem

Every capture spends money and nothing in the app says how much. A twenty-minute
recording is split into four transcription requests, enriched by a second model,
and — if it is an image — OCR'd by a third; then the source file sits in R2 and
its row sits in Turso for as long as the user keeps it. Today all of that is
invisible. There is no way to answer "what did this note cost me", and no way to
notice that switching an enrichment profile to a frontier model multiplied the
per-capture bill.

Nothing of this exists yet. A sweep of `lib/`, `test/` and `docs/` finds the word
"cost" only in prose comments; there is no price table, no usage record, and no
identifier resembling one.

## What this builds

1. A price book: default rates in code, per-model overrides in settings, edited
   in a new Config tab section.
2. A usage record: one row per API call, carrying what the provider actually
   counted and what it cost.
3. A per-capture cost readout on the queue card and in the inline editor, plus
   totals in Config.

## Decisions

### Usage comes from the provider, not from an estimate

The unit counts are read from the `usage` block the provider already returns in
the same response the pipeline parses for text. The alternative — deriving
tokens from character counts and audio seconds from `durationMs` — was rejected
because it produces a number indistinguishable from a measured one while being
roughly ±20% wrong, and the whole point of the readout is to be trustworthy
enough to act on.

The consequence is that a provider which returns no `usage` (local whisper.cpp,
Ollama) yields an event with no token counts. That is correct rather than
lossy: those endpoints also cost nothing, and their price book entry is an
explicit zero.

### One capture is many events

`ChunkedTranscriptionService` splits long audio into N sequential requests,
`retryTranscription` re-runs the whole processing pass, and `_enrich` is a
separate request after the transcript lands. So "the cost of a note" is a sum
over a list, not a single field. Usage is therefore stored as an append-only
event list keyed by capture id — the same shape `Recording.routes` and
`revisions.jsonl` already use, and for the same reason: a retry that cost money
a second time must be visible as a second charge, not folded into the first.

### `costUsd` is computed at record time and stored

The amount is a fact about what was paid, so a later price change must not
rewrite it. The single exception is the case the price book could not answer:
when `costUsd` is NULL because no rate existed, adding that rate backfills the
NULLs. There is nothing to overwrite there. Changing an *existing* rate never
touches history.

### Transcription bills by audio duration, not by tokens

Confirmed against provider pricing on 2026-08-09: OpenAI charges per minute of
audio for every transcription model (`gpt-transcribe` $0.0045/min,
`gpt-4o-transcribe` and `whisper-1` $0.006/min, `gpt-4o-mini-transcribe`
$0.003/min) and Groq charges per hour (`whisper-large-v3-turbo` $0.04/h,
`whisper-large-v3` $0.111/h). None of them bills transcription by token.

So the billable quantity for the transcription stage is `audioSeconds`, and
`inputTokens`/`outputTokens` on those events are detail rather than price basis.
The quantity is resolved in this order:

1. The `usage` block, when the provider reports a duration (`usage.type ==
   "duration"` on OpenAI). This is the provider's own count of what it billed.
2. The capture's own `durationMs`, passed down through `beginJob`. A local
   measurement of the same quantity, not an estimate.
3. Unknown.

**Case 3 is real and must be visible.** `MediaImporter` writes `durationMs: 0`
for every upload (`media_importer.dart:58`), and the `gpt-*-transcribe` family
returns token usage rather than a duration — so an uploaded audio file on one of
those models has no duration from either source. Pricing it as zero would be the
silent understatement this whole design exists to prevent.

### Missing rate is NULL, not zero

Null and zero are different claims — the same distinction `Recording.category`
already encodes (null = enrichment never ran; `capture` = it ran and could not
place the item). Here: a local Ollama model has a *known* rate of zero, while a
newly typed OpenAI model name has an *unknown* rate. Collapsing them would make
the queue total silently understate the bill with nothing reporting it.

A NULL-cost event still stores its token counts, so the backfill has something
to multiply once the rate arrives. The Config section lists every model that
produced NULL-cost events, with a call count, so the gap is visible rather than
inferred from a suspiciously low total.

**A NULL cost has two possible causes and they must not be confused**, which is
why the event carries `unpricedReason` (`noRate` / `noQuantity`) alongside the
NULL. `noRate` means the price book had no entry — fixable by typing a rate, and
backfillable afterwards. `noQuantity` means the rate exists but the billable
amount is unknown (the audio-duration case above) — typing a rate fixes nothing,
and listing that model under `MISSING RATES` would send the user to the wrong
control. The Config section reports the two separately.

### Defaults live in code; settings hold only overrides

`PriceBookDefaults.rates` is a `const` map in Dart with a `verifiedOn` date and
source URLs in the comment above it, exactly as `ProviderPreset.all` already
documents its model lists. `AppSettings.priceOverrides` holds only what the user
changed, and — like `shortcuts` and `enrichmentInstructions` — its key is omitted
from the settings payload while the map is empty.

This is what satisfies "prices are updated from time to time": a later build
ships a fresh price book to everyone who never edited one, while a hand-corrected
rate stays hand-corrected. Copying the whole table into settings on first write
would freeze every install on the price book of its installation day.

Lookup key is the model name alone, not provider+model: the same model through a
proxy costs the same, and model names are unique in practice.

### Storage is a rate, not a charge

Storage bills per GB-month, so there is no one-off "cost of this capture". The
card shows `sizeBytes` × the GB-month rate — a monthly rate for that item —
computed at render time with nothing persisted. Accumulating it from `createdAt`
was rejected because the same card would show a different number tomorrow with
no event having occurred.

### `UsageSink` rather than wider return types

`usage` arrives in the HTTP envelope, inside `HttpWhisperTranscriptionService`,
`HttpChatEnrichmentService` and `HttpVisionOcrService` — each sitting under one
or two decorators (`VideoTranscriptionProcessor` → `ChunkedTranscriptionService`
→ `Http…`) that all declare `Future<String>`.

Widening those return types to carry usage was rejected: it rewrites `Processor`,
`ProcessorRegistry`, both audio processors, the chunking decorator and every
hand-written fake in the suite, and forces the chunking decorator to sum usage
itself. Wrapping `http.Client` in an interceptor was rejected too — it cannot
tell which stage it is observing, and the transcription path uses
`MultipartRequest`/`send` rather than `post`, so it is two interception points
anyway.

Instead: a `UsageSink` seam of exactly the shape this repo already uses four
times (`LogSink`, `ClipboardSink`, `MediaOpener`, `RevisionsRepository`) —
interface in `domain/`, `NoopUsageSink` as the default, injected into the three
HTTP classes. Each calls `sink.record(...)` after a successful response. No
contract changes, no fake touched, and chunking emits N events for free because
every part goes through the same HTTP class.

The HTTP classes do not know the capture id. `RecordingsController._processOne`
supplies it with an explicit `usage.beginJob(id, stage)` / `endJob()` pair in a
`finally`. That is ambient state and will be written as such, together with the
reason it is safe: `_drainProcessingQueue` is single-flight and `_enrich` runs
inside the same `_processOne`, so exactly one job is ever active.

## Architecture

New feature directory `lib/features/costs/`, following the house layout.

### `domain/usage_event.dart`

```
id           uuid
captureId    owning capture
stage        transcription | ocr | enrichment
provider     endpoint host (api.openai.com) — grouping key in Config
model        model name; '' when the profile sets none
at           timestamp
inputTokens  nullable — absent when the provider reports none
outputTokens nullable
audioSeconds nullable — the billable quantity for the transcription stage
costUsd      nullable — NULL means the event could not be priced
unpricedReason nullable — noRate | noQuantity; set exactly when costUsd is NULL
```

`fromJson` follows the house rule: every field defaults when absent, unknown
`stage` names drop the row rather than throwing out of the load.

### `domain/model_price.dart`

`inputPerMTok`, `outputPerMTok`, `perAudioMinute` — all nullable, because a
duration-billed model has no token rate and vice versa.

### `domain/price_book.dart`

`PriceBookDefaults.rates` (const, with `verifiedOn` and sources) and
`PriceBook.lookup(model)` → override ?? default ?? null.

Storage rates are a separate type, `StoragePrice` (`r2PerGbMonth`,
`tursoPerGbMonth`), because they are two scalars rather than a per-model map.
They follow the same three-state rule: `AppSettings.storagePriceOverride` is
private and nullable — absent means "use the shipped defaults", present means
"authoritative, including a deliberate zero" — and the key is omitted from the
settings payload while untouched.

Local models (`qwen2.5vl`, `llama3.2-vision`, `gemma3`, `llava`, whisper.cpp)
get an explicit zero entry.

### `data/usage_repository.dart` + `AppDatabase`

```sql
CREATE TABLE IF NOT EXISTS usage_events (
  id TEXT PRIMARY KEY,
  capture_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  at INTEGER NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  audio_seconds REAL,
  cost_usd REAL,
  unpriced_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_usage_capture ON usage_events(capture_id);
CREATE INDEX IF NOT EXISTS idx_usage_at ON usage_events(at DESC);
```

Append-only in practice. The only `UPDATE` is the backfill, and it is scoped to
`WHERE cost_usd IS NULL AND model = ?`.

### `data/recording_usage_sink.dart`

Prices the event through `PriceBook`, writes the row, and swallows every error
into `LogSink` under the `ClipboardSink` contract. A failed cost write must cost
a number, never a capture.

### Usage parsing

Three response shapes to handle, all inside the classes that already hold the
decoded envelope:

- `usage.{prompt_tokens, completion_tokens}` — chat completions
- `usage.{input_tokens, output_tokens}` and `usage.{type: "duration", seconds}`
  — OpenAI transcriptions
- `x_groq.usage` — Groq

A response with no `usage` at all produces an event with null counts, not an
exception.

## UI

### Config — new `PRICING` section

Its own file, `costs/presentation/pricing_section.dart`, placed above the
existing `STORAGE` section. `config_tab.dart` is already past 500 lines with
seven sections; `enrichment_context_section.dart` and `vault_section.dart` set
the precedent.

- Summary line: `THIS MONTH $1.24 · ALL TIME $8.90 · STORAGE 2.1 GB ≈ $0.03/mo`
- Rate table: one row per model, editable inline; an edited value becomes an
  override and gets a `custom` marker with a reset. Only models present in the
  user's profiles or in the event history are listed — not forty rows for
  providers nobody uses. Footer: `defaults verified <date>`.
- `MISSING RATES`: models whose events are NULL-cost for `noRate`, with call
  counts. Adding a rate triggers the backfill. Events NULL for `noQuantity` are
  reported on their own line — no rate would fix them, so they must not appear
  here.

### Queue card

`VerificationLine` extends to `file verified · 6.8 MB · $0.0021 · persisted`,
and to `· cost —` when no rate is known. Note: that widget currently has a
`const` constructor while painting `Console.green`; extending it requires
dropping `const`, per the theme rule in CLAUDE.md.

### Inline editor

A collapsed `COST` section below `HISTORY`, built the same way as
`RevisionHistorySection`: one row per event
(`TRANSCRIPTION · gpt-transcribe · 12 400 in / 890 out · $0.0018`), with the
storage rate on the last line.

No snackbars, no dialogs — the app's existing rule.

## Testing

Pure Dart throughout, except one widget test for the Config section.

- `usage_parsing_test` — the three `usage` shapes, plus a response with none.
- `price_book_test` — override > default > null; local model is an explicit
  zero, not null; pricing from tokens and from audio minutes.
- `usage_event_test` — round trip and legacy defaults, per the house rule for
  every persisted type.
- `cost_aggregation_test` — sum across N chunks and across a retry; the backfill
  touches only `cost_usd IS NULL` rows.
- Resilience: a `UsageSink` that throws on every `record` leaves the capture's
  status and transcript untouched. Same contract the `ClipboardSink` tests pin.

Per CLAUDE.md, each new test is seen red before it is trusted: break the fix,
watch it fail, restore.

## Rollout

No data migration. `usage_events` starts empty; captures taken before this
feature have no cost and are **not** estimated retroactively — that would
produce exactly the indistinguishable-from-measured number this design rejected
up front. The card shows a cost only when events exist.

Order, each step independently testable:

1. `domain/` — `UsageEvent`, `ModelPrice`, `PriceBook` and its defaults. Default
   rates were read from each provider's pricing page on 2026-08-09 and are
   listed in the implementation plan; they are stamped with that `verifiedOn`
   date and were not written from memory.
2. `data/` — the table in `AppDatabase` and `UsageRepository`.
3. `UsageSink` and `usage` parsing in the three HTTP classes.
4. `beginJob`/`endJob` in `_processOne`; wiring in `SettingsController`.
5. UI — `PRICING`, the card line, the editor's `COST` section.

Steps 1–4 are invisible: the app collects data and displays nothing. That is
deliberate, so the UI has history to render the day it lands.

## Out of scope

Turso sync for `usage_events`, budgets and alerts, CSV export.

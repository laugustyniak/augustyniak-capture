# Capture segments: adding a fragment to a note that already exists

Status: **shipped** · Owner: laugustyniak · Scope: a capture may gain further
source artifacts after it has been accepted — a second recording, a typed
addition, a picked file — without becoming a second capture and without
disturbing the ordering guarantee that governs the first one.

## Why this exists

A thought arrives in pieces. Today the app can only accept the first piece: a
capture is created from exactly one source artifact, and every later thought
about the same subject becomes a new row in the queue that the user then has to
reconcile by hand — or, more often, does not. The queue grows two entries for
one idea, the transcript of each is half the story, and enrichment names both
of them badly because neither carries the whole thing.

`Recording` is singular throughout: one `filePath`, one `sizeBytes`, one
`contentHash`, one `durationMs`, one `type`. Twenty-eight call sites in `lib/`
read `.filePath` directly. So "add another fragment" is not a feature that fits
beside the model; it is a change to what a capture *is*.

**What it deliberately does not become:** a thread of child rows. A parent with
`parentId` children keeps every existing behaviour intact at the price of
making every question ambiguous — is the thread closed, or the row? enriched
per fragment, or per thread? routed once, or three times? The queue's whole
vocabulary (`isProcessedByUser`, `routes`, closures) is written about one item,
and duplicating it per thread is a larger change than the one below while
delivering less.

## The shape

### 1. `CaptureSegment`

New type in `recordings/domain/capture_segment.dart`:

```
CaptureSegment { index, filePath, type, sourceMimeType,
                 createdAt, durationMs, sizeBytes, contentHash,
                 text, error }
```

A segment carries **its own `CaptureType`**, never the parent's. A photo of a
whiteboard appended to an audio note must reach `OcrProcessor`, and
`ProcessorRegistry` maps `CaptureType → Processor` — so the segment, not the
capture, is the unit of processing. It carries its own `text` and `error` for
the same reason: it is also the unit of retry.

A segment is **pending** when `text == null`. That is the only definition; no
per-segment status enum is introduced, because `RecordingStatus` already
answers "queued/running/failed" for the capture and a second persisted enum
would be a second thing to keep in agreement with it.

### 2. Top-level source fields describe segment 0, exactly and always

`filePath`, `type`, `sourceMimeType`, `sizeBytes` and `contentHash` continue to
describe the first segment and nothing else. Aggregates are **getters**
(`totalDurationMs`, `totalSizeBytes`) which the UI reads.

This is not conservatism. `contentHash` and `sizeBytes` are the archive's
deduplication contract: they must describe the bytes that `filePath` points at,
or import loses the difference between *these are the same bytes* and *this
archive came from this library* — the distinction `RestoreSummary.
matchedByIdAlone` exists to report. A hash recomputed over all segments would
also change every time a fragment is appended, so an archive taken yesterday
would stop recognising its own capture and restore a duplicate of it.

`transcript` is the one exception and keeps its current meaning: the effective
text of the whole capture (see §5).

`durationMs` stays segment 0's. The card reads `totalDurationMs`.

### 3. Backward compatibility, both directions

A stored row with no `segments` key synthesises one segment from the top-level
fields — the same legacy-defaulting point `CaptureType.fromName(null)` is.

An **older build** reading a row written by this one sees the first fragment
and the full transcript. That is the honest degradation: it shows less than
there is and says nothing false. It is the direct consequence of §2 and the
reason §2 is worth its cost.

### 4. Files, and the three places that break silently

Segment 0 keeps `<id>.<ext>`. Segment *n* is `<id>-<n>.<ext>`.

| Site | Today | Required change |
| --- | --- | --- |
| `RecordingsRepository.findOrphans` (`recordings_repository.dart:381`) | matches directory files against known **ids**, and `basenameWithoutExtension('<id>-1.m4a')` is `'<id>-1'` | match against the basenames of every segment of every row |
| `RecordingsRepository.deleteArtifacts` (`:54`) | deletes `filePath` plus the poster | deletes every segment and every poster |
| `ZipCaptureArchive` (`zip_capture_archive.dart:414, 444, 572`) | one payload member per row; `_relocate` re-points one path | one member per segment; `_relocate` re-points all of them, and the manifest sizes each |

`findOrphans` is the dangerous one, because it fails **later and quietly**:
appending works, everything looks right, and on the next launch the orphan
sweep re-adopts `<id>-1.m4a` as a separate capture holding the same audio. No
test in the suite sees it — `recoverOrphans()` is called by the shell after
`initialize`, never from inside it, precisely so the widget suites do not scan
a real directory.

`TursoSyncService` re-roots the paths inside `json_payload` on pull
(`turso_sync_service.dart:94`). It must walk the segments too, or a capture
pulled from the cloud has its first fragment in place and the rest pointing
into another device's container.

### 5. The append pipeline

`RecordingsController.appendSegment` (reached by three entry points: record,
type, pick a file) holds the identical order the capture lifecycle mandates:

1. obtain the source bytes into `<id>-<n>.<ext>`
2. verify the file exists **and** `length > 0`, else throw `FileSystemException`
3. append the `CaptureSegment`, set `status = pendingTranscription`, set
   `isProcessedByUser = false`
4. `saveAll()` — atomic persist
5. `_enqueueProcessing(id)` and return

**New rule, and the one this feature adds to the existing set: the parent row
is not touched until the fragment's file has passed step 2.** The
persist-before-process guarantee governs a capture the app has accepted; this
is the first path where an accepted capture changes, so the failure of the new
fragment must cost nothing that already existed. A failed append leaves the row
byte for byte as it was, and the partial file is deleted the way
`discardRecording` deletes one — left on disk it is exactly what
`recoverOrphans()` re-adopts.

Appends take the same `_isBusy` lock as every capture entry point, so no two
captures and no capture-plus-append ever run at once. `addTextNote` and
`addImportedFile` gain an optional `appendTo: id`; there is no second way into
the queue and no second write path.

### 6. Processing: only what is pending

`Processor.process(Recording)` becomes `Processor.process(CaptureSegment)`. All
four implementations read only `item.filePath` today
(`transcription_processor.dart:22`, `ocr_processor.dart:18`,
`video_transcription_processor.dart:24`, `processor.dart:23`), so this is
mechanical rather than a rewrite.

`_processOne(id)` runs **every pending segment, in index order**, each through
`_registry.forType(segment.type)`, each with its own usage-scope
`audioSeconds`. A segment that already has text is never sent again: that is
money spent on text the app already holds.

A segment that throws records its own `error`; the capture lands `failed`, and
the text of the segments that succeeded **stays**. `retryTranscription` re-runs
only the pending ones.

The clipboard hand-off, `_enrich` and `_mirrorToVault` run **once, after every
pending segment has settled**, on the whole text, in the existing order
(`completed → clipboard → enrich → mirror`).

Posters: `_extractPoster` runs per video segment. `thumbPath` remains segment
0's, under the §2 rule.

### 7. Text accumulates; it is never recomputed

On the first time a segment gains text:
`transcript = transcript + "\n\n" + segment.text`. Exactly once per segment.

The join is **not** recomputed from `segments`, because `editTranscript` exists
and people correct transcripts. A recompute after an append would silently undo
a hand correction — the same shape as the rolled-back-transaction bug that
`recordings.db-stale` exists to prevent, and equally invisible: both stores
would be internally consistent and only disagree with what the user typed.
Segments keep their own `text` for provenance and retry; `transcript` holds the
truth. `revisions.jsonl` records the overwrite either way.

No separators and no timestamps are injected into the text. Fragment
boundaries are shown in the editor, not in the content that reaches
`inbox.md`, the agent brief and the vault — all three render it as markdown,
and decoration this app invented would arrive there as the user's own words.

### 8. Re-opening a capture that was already finished

An append sets `isProcessedByUser = false` and lets enrichment run again over
the fuller text. Field ownership is unchanged: `title` is written only when
blank and `category` only when null, `summary` refreshes, AI tags are replaced
and human tags survive.

`routes` is **not** touched. The delivery happened; a fuller text does not
un-send it. What returns to the user is the decision to route again, which is
what putting the capture back on the desk is for.

**Closing it a second time does not count a second time.** `_closedIds`
enforces that a capture closes once ever, so the momentum tally does not move.
That is the existing rule working, not a defect — recorded here because it
reads like one.

### 9. UI

- `+ FRAGMENT` in `RecordingEditor` and in the expanded compact `RecordingRow`,
  offering record / text / file — the same three actions as the capture dock.
- Recording a fragment reuses `RecordingView`, headed with the note it appends
  to, named through `displayNameFor` so it matches the row on screen.
- A `FRAGMENTS` section in the editor: index, type icon, duration or size,
  play.
- **No per-segment delete in this slice.** `transcript` accumulates, so
  removing a segment cannot take its text back without guessing at which part
  of an edited transcript belonged to it. Deletion stays per capture.

### 10. Vault

`MarkdownNoteVault` copies every segment source into `attachments/` and embeds
one `![[…]]` per file, under the existing `vaultCopySources` flag. A text
segment never attaches its own `.txt`, exactly as a text capture does not — it
is the body printed above.

### 11. SQLite

Segments live in `json_payload` only; no new column. A row rebuilt from the
column subset therefore loses them exactly as it loses `transcript`, and the
existing mechanism covers it — `_loadFromDatabase` already tracks the ids it had
to rebuild from columns and prefers the index's version of those rows.
`test/sqlite_index_divergence_test.dart` gains a segment case, and the note in
`CLAUDE.md` naming `transcript` gains `segments` beside it.

## Tests

Each must be seen red before the change that makes it pass:

- legacy JSON with no `segments` loads as exactly one segment, with the
  top-level fields preserved
- an append whose file fails verification leaves the parent row unchanged and
  leaves no file behind
- `findOrphans` does not re-adopt `<id>-1.m4a` while its row exists
- `deleteRecording` removes every segment file and every poster
- a failed segment leaves earlier segments' text intact; `retryTranscription`
  re-runs only the pending one
- archive round trip with a two-segment capture: every member present, every
  path re-rooted, and a re-import counts it `alreadyPresent`
- appending to a closed, enriched capture clears `isProcessedByUser`, refreshes
  `summary`, keeps `title` and human tags, and leaves `routes` untouched
- a hand-edited transcript survives a subsequent append

## Out of scope

| Not building | Why |
| --- | --- |
| A global "append to last note" hotkey | "Last" is ambiguous between created and touched, and a mistake files a thought into the wrong note with no undo. |
| Per-segment delete | See §9. Needs a text model that can attribute parts of an edited transcript to a segment; nothing needs that yet. |
| Re-ordering segments | Order is arrival order, which is the only order the accumulated transcript can be reconciled with. |
| Merging two existing captures | A different feature with a different failure mode (two `routes` lists, two closure records). |

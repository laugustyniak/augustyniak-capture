# Capture result view and thread — design

Date: 2026-11-20 · Issue: #444 · Base: `main` at `f38af4a`

## Problem

After a dictation the user gets no next step and almost no feedback: the focused capture shows a status line ("Queued for processing.") and later the text. Copy is the end of the interaction. The capture should be interactive.

## Decision

**Deepen the single capture (bottom-up); defer grouping.** Most of the capability already exists and is hidden:

- appending fragments: `Recording.segments`, `onAppendRecording` / `onAppendNote` / `onAppendUpload`
- agent follow-up: `NativeAgentJobs.followUp`, the editor's AGENT RUNS
- agent results: `cleanup` (#258), `instruction` (#281), `suggestedRoute`, `commitments` (#251), `artifacts`, `routes` + `outcome`, `revisions.jsonl`

Segments, routes and artifacts already travel through sync, backup and MCP, so this direction adds no new persisted entity. A group/thread/task entity would be a new row type across the sync RPC, a Supabase migration + RLS + pgTAP, the backup archive, the SQLite mirror, NoteVault and MCP, and a third organising axis next to projects and REVIEW CONNECTIONS / triage digest (#250). If grouping proves necessary, start as a *merge* proposal from the triage digest (move segments into one capture), not a new entity.

**Name stays "Capture".** The app is named after it, agents call `search_captures` / `get_capture` / `list_project_captures`, and the domain type is `Recording`, so it is UI copy only. The chronological view inside a capture is labelled THREAD.

## Design: capture result view

Shown on the focused capture right after STOP, top to bottom:

1. live pipeline strip: `SAVED ✓ verified · 6.8 MB` → `QUEUED` / `TRANSCRIBING` → `DONE` (+ enriched)
2. result: title · category · priority, instruction or transcript, cleanup accept/reject inline
3. at most three next actions, `suggestedRoute` first, then SMART (#386) when available, COPY
4. continue: `+ FRAGMENT` (voice / note / file), `FOLLOW-UP` (voice)
5. THREAD: segments, revisions, routes, agent runs and their outcomes, follow-ups, oldest first

## Open decision: fragment (content) vs follow-up (instruction)

Segments accumulate into `transcript`, which is never recomputed. A dictated "turn this into a Todoist task" appended as a plain segment would leak into search, enrichment, NoteVault, MCP output and agent briefs.

**Default:** `CaptureSegment.role` = `content` | `instruction`. Absent key = `content`, so legacy rows serialise byte for byte. An instruction segment follows persist-before-process and per-segment retry but never enters `transcript`. Dispatch: to the agent conversation via `followUp` when the capture has a run with a conversation id, otherwise a transform of the capture (new `instruction`, recorded as a revision).

## Slices

| # | Slice | Persisted change | Invariant it leans on | Related |
|---|---|---|---|---|
| S1 | Result view after STOP: pipeline strip, result, ≤3 actions, promoted fragment controls | none (view) | none new | its own issue |
| S2 | THREAD timeline | none (view) | read-only | |
| S3 | `CaptureSegment.role` + voice FOLLOW-UP | yes (round-trip + legacy test) | persist before process; parent row untouched until the fragment file is verified | replaces Reply in #252 |
| S4 | Follow-up dispatch (agent or transform); SMART as primary action | none | delivery first, state second | absorbs #386; #256 local only |
| S5 | (later) merge captures from the triage digest | none | removal paths unchanged | #250 |

## Risks / stop conditions

- Before S3: check how `sync_row_codec` serialises segments. An older client reading `role: instruction` treats it as content (acceptable: `transcript` is not recomputed). STOP if the codec rejects unknown keys.
- S1/S2 need a screenshot from a widget test or headless run, never the desktop app on the live library.

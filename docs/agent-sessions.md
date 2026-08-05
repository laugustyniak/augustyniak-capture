# Agent sessions

Augustyniak Capture can open a coding agent directly in a project's repository.
The project owns the working directory, optional Zellij session name, default
agent, additional CLI arguments, and an initial prompt. This makes a captured
agent task executable context rather than text that still needs to be copied and
reconstructed elsewhere.

## Prerequisites

Session launch currently requires macOS plus:

- [Ghostty](https://ghostty.org/) as the terminal,
- [Zellij](https://zellij.dev/) for named, reusable sessions,
- at least one supported agent CLI on `PATH`:
  - `codex` for Codex,
  - `claude` for Claude Code,
  - `agy` for Antigravity. **AGY is the Antigravity CLI abbreviation.**

Verify the environment before creating a project:

```bash
test -d /Applications/Ghostty.app && echo "Ghostty installed"
command -v zellij
command -v codex   # if you use Codex
command -v claude  # if you use Claude Code
command -v agy     # if you use Antigravity
```

Only one agent CLI is required. Install and authenticate the agent you intend to
launch; Augustyniak Capture starts the local executable but does not install it,
manage its account, or provide its credentials.

## Create a project

1. Open **Projects** and select **Add project**.
2. Give the project a stable name and choose its repository directory.
3. Optionally add a short description. The repository remains the source of
   truth for richer context through `CLAUDE.md`, `AGENTS.md`, or `README.md`.
4. Choose Codex, Claude Code, or Antigravity as the default agent.
5. Optionally set a Zellij session name, agent-specific arguments, and an initial
   prompt such as `Read AGENTS.md and pick up the first open task.`
6. Save, then use the agent action on the project card.

The first launch opens Ghostty, creates a named Zellij session rooted in the
repository, and starts exactly one selected agent. Later launches attach to that
session instead of starting a duplicate agent.

## Hand a capture to an agent

The project card starts a session with no particular task in hand. To start one
*on something you captured*, use the agent button on the capture itself — in the
Queue, on a card or an expanded row, or with `A` on the focused row.

The sheet that opens shows three things and launches on one tap:

1. **Agent** — the project's default is preselected; choosing another applies to
   this task only and does not change the project.
2. **Opening prompt** — a single line pointing the agent at the brief. Editable,
   so `only write tests` or `open a PR when green` costs one sentence.
3. **The brief's path** — `.agent-tasks/<capture-id>.md` inside the repository.

The full capture (title, summary, tags and the transcript or OCR text) is written
to that file *before* the session opens; the prompt only points at it. That is
why a twenty-minute dictated note travels intact where a command-line argument
would have been truncated somewhere along the way without saying so.

The capture then closes itself and records where it went, exactly as routing to
the inbox does. A failed launch leaves it open and retryable.

**Handing off twice appends.** The brief file gains a second `## Handoff`
section rather than being rewritten, so anything the agent wrote underneath —
notes, results, a PR link — survives. Add a `## Result` section there and it
becomes the place to look when the session is over.

**If the session was already running**, the sheet stays open and says so. Zellij
attaches to a live session; it does not deliver a new prompt to the agent inside
it. Copy the prompt from the sheet and paste it into that session, or close the
session first and hand off again.

## Recommended repository brief

Add an `AGENTS.md` at the repository root. Keep it operational and short enough
to remain useful as the opening context:

```markdown
# AGENTS.md

## Outcome
What the product does and the current objective.

## Run locally
Exact install, run, test, and lint commands.

## Architecture
The few boundaries an agent must preserve.

## Constraints
Security, data, compatibility, cost, and deployment requirements.

## Definition of done
Observable checks required before work is complete.
```

This file is a compounding project asset: every supported agent receives the
same operating context, onboarding becomes cheaper, and instructions stay under
version control instead of living in one provider's conversation history.

## Failure modes

- **Nothing opens:** confirm Ghostty is installed as `Ghostty.app` and `zellij`
  is on `PATH`.
- **The terminal opens but the agent fails:** run its executable directly and
  finish installation or authentication.
- **The wrong repository opens:** edit the project's repository path; it must be
  an existing local directory.
- **A changed prompt is not used:** close the existing Zellij session first.
  Reopening an existing project-agent pair intentionally attaches to the running
  session and does not start a second process.

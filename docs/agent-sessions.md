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

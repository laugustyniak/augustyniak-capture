# Agent sessions

A capture filed as `agentTask` can become work an agent actually does. There are
**two ways that happens, and which one applies is decided by the project** — not
by the capture, and not by a choice made at hand-off time.

| | Bound project | Unbound project |
|---|---|---|
| Where it runs | any host in the fleet | this machine |
| Started by | the Command control plane | a terminal + Zellij, here |
| Second hand-off | updates the same brief | attaches to a live session, delivering nothing |
| Reports back | state, issues, a PR link | nothing, ever |
| Needs | an aggregator address and a fleet token | a terminal, Zellij, an agent CLI |

A project is *bound* when it names a Command host and workspace (Projects → edit
→ **Command binding**, two pickers over a live read of the fleet). Everything
below the binding section of this document describes the **unbound** path.

## Which one you want

**Bound, in almost every case.** The control plane spawns on any host, keeps the
session in a fleet snapshot, refuses a second start of one already running, and
returns an outcome the capture then shows on its own card. Set it up in Config →
**Command control plane**, then bind the project.

**Unbound is the offline case, and it is a real one**: one machine, no collector
running, and you want an agent in a terminal now. It costs one file to keep and
it is kept deliberately. What it cannot do is equally deliberate — it will not
gain more hosts, status tracking, or a way to deliver a second prompt, because
every one of those exists on the other side and building them twice is the cost
this integration was designed to avoid.

The hand-off sheet says **local session — not supervised** whenever it is about
to take this path. Without that label the two look identical, and they differ in
whether anything will ever tell you what happened.

## Prerequisites (unbound path)

Launching locally requires **macOS or Linux**, plus:

- a terminal the app can drive,
  - macOS: [Ghostty](https://ghostty.org/), installed as `Ghostty.app`,
  - Linux: the first of `ghostty`, `wezterm`, `kitty`, `alacritty`, `konsole`,
    `gnome-terminal`, `xfce4-terminal` that is installed;
- [Zellij](https://zellij.dev/) for named, reusable sessions,
- at least one supported agent CLI on `PATH`:
  - `codex` for Codex,
  - `claude` for Claude Code,
  - `agy` for Antigravity. **AGY is the Antigravity CLI abbreviation.**

**Windows is not supported and is not a gap waiting to be filled.** Zellij has no
native Windows build, and the named-session model — attach an existing session,
or start a new one from a layout — is Zellij's rather than the terminal's. A
Windows path would be a different design with no `attachedToExistingSession`, so
the app shows no agent button there rather than a control that cannot work.

Verify the environment before creating a project:

```bash
# macOS
test -d /Applications/Ghostty.app && echo "Ghostty installed"
# Linux — any one of these is enough
command -v ghostty wezterm kitty alacritty konsole gnome-terminal xfce4-terminal

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

## Hand a capture to a local agent

**This section applies to unbound projects only.** A bound project's `agentTask`
captures leave through the control plane when you route them, and the local
agent button is not offered at all — one capture with two ways out that differ
only in whether anything answers would be a choice nobody can make well.

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

- **The agent button is missing on a capture:** its project is bound to Command.
  That is the supervised path — route the capture instead, and watch the outcome
  line on its card.
- **Nothing opens:** confirm the terminal is installed — `Ghostty.app` on macOS,
  or one of the seven supported terminals on Linux — and that `zellij`
  is on `PATH`.
- **The terminal opens but the agent fails:** run its executable directly and
  finish installation or authentication.
- **The wrong repository opens:** edit the project's repository path; it must be
  an existing local directory.
- **A changed prompt is not used:** close the existing Zellij session first.
  Reopening an existing project-agent pair intentionally attaches to the running
  session and does not start a second process.

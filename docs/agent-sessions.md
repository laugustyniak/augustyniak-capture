# Agent sessions

A capture filed as `agentTask` can become work an agent actually does. There are
**two ways that happens, and which one applies is decided by the project** — not
by the capture, and not by a choice made at hand-off time.

| | Bound project | Unbound project |
|---|---|---|
| Where it runs | any host in the fleet | this machine |
| Started by | the Command control plane | a native background job or a terminal + Zellij |
| Another hand-off | updates the same brief | starts a fresh job; Jobs can explicitly follow up |
| Reports back | state, issues, a PR link | local status, output, result and exit code |
| Needs | an aggregator address and a fleet token | an agent CLI; Zellij only for windowed sessions |

A project is *bound* when it names a Command host and workspace (Projects → edit
→ **Command binding**, two pickers over a live read of the fleet). Everything
below the binding section of this document describes the **unbound** path.

## Which one you want

**Bound, in almost every case.** The control plane spawns on any host, keeps the
session in a fleet snapshot, refuses a second start of one already running, and
returns an outcome the capture then shows on its own card. Set it up in Config →
**Command control plane**, then bind the project.

**Unbound is the offline case**: one machine and no collector. A background run
is supervised locally and stays visible under **Projects → Jobs** after Capture
closes and reopens. A windowed run keeps the older Zellij path.

## Prerequisites (unbound path)

Launching locally requires **macOS or Linux** and the selected agent CLI. A
windowed run additionally requires:

- a terminal the app can drive,
  - macOS: [Ghostty](https://ghostty.org/), installed as `Ghostty.app`,
  - Linux: the first of `ghostty`, `wezterm`, `kitty`, `alacritty`, `konsole`,
    `gnome-terminal`, `xfce4-terminal` that is installed;
- [Zellij](https://zellij.dev/) **0.41 or newer** for named, reusable sessions
  (`attach --create-background` is what starts one with no window),
- at least one supported agent CLI on `PATH`:
  - `codex` for Codex,
  - `claude` for Claude Code,
  - `agy` for Antigravity. **AGY is the Antigravity CLI abbreviation.**

Native background supervision currently uses POSIX process groups and supports
macOS and Linux. The windowed path also uses Zellij, which has no native Windows
build. The app therefore hides local agent controls on Windows rather than
offering a launch mode it cannot supervise or attach to.

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
   To run an agent without per-tool approval prompts, turn on **Skip permission
   prompts** in its section rather than typing the flag. Each CLI spells it
   differently — Codex wants `--dangerously-bypass-approvals-and-sandbox`, Claude
   Code and Antigravity `--dangerously-skip-permissions` — and a CLI handed the
   wrong spelling exits before it reads the prompt. The editor refuses a typed
   permission flag, and a project saved with one has it converted to the switch
   on load.
6. Save, then use the agent action on the project card.

A tap asks for the opening prompt and starts a native agent job in the
background. **Jobs** shows its status, bounded output, result and exit code, and
can stop a running job. After it reaches a terminal state, **Follow up** starts
a new local job against the exact provider conversation id. A long press keeps
the previous Zellij path and opens the session in a terminal window. Gemini CLI
is window-only; native background runs support Codex, Claude Code and AGY.

**Stop** requests graceful termination. A job stays **Stopping** until its
process exits; a process that ignores the request is not reported as stopped.

## Hand a capture to a local agent

**This section applies to unbound projects only.** A bound project's `agentTask`
captures leave through the control plane when you route them, and the local
agent button is not offered at all — one capture with two ways out that differ
only in whether anything answers would be a choice nobody can make well.

The project card starts a session with no particular task in hand. To start one
*on something you captured*, use the agent button on the capture itself — in the
Queue, on a card or an expanded row, or with `A` on the focused row.

The sheet that opens shows four things and launches on one tap:

1. **Agent** — the project's default is preselected; choosing another applies to
   this task only and does not change the project.
2. **Where it runs** — **DETACHED · NO ZELLIJ** (the default) starts a native
   background job with no window, no terminal and no Zellij; **WINDOW · ZELLIJ**
   opens your terminal on a Zellij session straight away.
3. **Opening prompt** — the capture's own text. Editable, so `only write tests`
   or `open a PR when green` costs one sentence.
4. **The brief's path** — `.agent-tasks/<capture-id>.md` inside the repository.

The full capture (title, summary, tags and the transcript or OCR text) is written
to that file *before* the session opens; the prompt only points at it. That is
why a twenty-minute dictated note travels intact where a command-line argument
would have been truncated somewhere along the way without saying so.

The capture then closes itself and records where it went, exactly as routing to
the inbox does. A failed launch leaves it open and retryable.

**After a background launch the sheet stays open** and says "Running in the
background", with the session name, **ATTACH** — which opens your terminal on
the session — and a copy button for `zellij attach <name>`, for a terminal you
already have open. The capture's card keeps an **ATTACH** action on its route
line for as long as the session runs, so you can come back to it tomorrow. A
session that has ended is refused by name; hand the capture off again to start
a new one.

Starting in the background works on a machine whose terminal cannot open a
window at all (WezTerm failing with `egl Initialize: BAD_ACCESS`, for one): only
Zellij and the agent CLI are needed to start, and the terminal is asked for only
when you attach. If that terminal cannot open either, the copied command in your
own shell is the way in.

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
- **Nothing opens:** a background launch opens nothing by design — look for the
  green notice or the snackbar, then ATTACH. For a window, confirm the terminal
  is installed — `Ghostty.app` on macOS, or one of the seven supported
  terminals on Linux — and that `zellij` is on `PATH`.
- **ATTACH says the session is not running:** the agent exited, or the Zellij
  server went down with the shell it was started from. `zellij ls` lists what
  is alive; hand the capture off again to start a fresh session. On Linux the
  server lives in the app's cgroup, so an app started from a terminal pane
  takes its sessions down with that pane — start the app from the launcher
  (`tool/deploy.sh` installs the desktop entry) and they outlive it.
- **The terminal opens but the agent fails:** the Zellij pane shows the
  agent's exit and its error above it. An `unexpected argument` or
  `unknown option` means the project's additional arguments are wrong for that
  CLI; otherwise run its executable directly and finish installation or
  authentication.
- **The wrong repository opens:** edit the project's repository path; it must be
  an existing local directory.
- **A changed prompt is not used:** close the existing Zellij session first.
  Reopening an existing project-agent pair intentionally attaches to the running
  session and does not start a second process.

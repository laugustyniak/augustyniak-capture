# Switchboard: a deterministic next step for every capture

Status: proposed (#458). Date: 2026-11-22.

## Problem

Every exit from the desk today is a human tap. That covers the `inbox.md` file, a local agent session, a Command brief and Send to…. The one automatic choice, `ProjectCaptureRouter` (`lib/features/recordings/data/command_router.dart:152`), hard-codes two branches. Captures hold anything: a task, an idea, a meeting note, a request for an agent. We want a role that looks at each capture after enrichment, together with the user's own context, and decides:

- whether to act at all
- which exit to use
- when that exit is an agent, which CLI and in which mode, following the user's primary environment (Claude Code, Codex or OpenCode) rather than one hard-wired agent

It records what it did and why, and takes the capture off the desk when something was dispatched.

## Decision

**A pure Dart rule table, run after enrichment. No orchestration framework, and no LLM supervisor.**

### What exists in the market, and why none of it is the brain

| Category | Examples | How they route | Drive CLI agents? |
|---|---|---|---|
| Graph / supervisor frameworks | LangGraph, Google ADK, Mastra, Microsoft Agent Framework (AutoGen's successor) | An LLM returns structured output and code picks the branch (LangGraph), or a fixed workflow runs (ADK) | No. Each CLI must be wrapped as a tool or subprocess |
| Handoffs | OpenAI Agents SDK | The model picks a handoff, gated by `is_enabled` / `on_handoff` | No |
| Agent SDK with hooks | Claude Agent SDK | Subagents, `PreToolUse` deny, `SubagentStop` | Claude only |
| Shared CLI protocol | Agent Client Protocol (Zed): `claude-agent-acp`, `codex-acp`, `opencode acp` | None; it is a transport | Yes |
| Multi-agent GUIs | Vibe Kanban (company shut down 2026-04, now community-maintained), Conductor (macOS; Claude and Codex), claude-squad (tmux) | A human picks | Partly. No stable trigger API, no completion callback |
| Queues / workflow engines | Temporal, n8n | None | Too heavy for one user. A jobs table in the app is enough |
| An agent as the router | OpenCode custom agents (`mode: primary/subagent`, `opencode serve`), Claude Code `--agent` | An LLM decides | Only themselves |

Anthropic's *Building effective agents* names this exact pattern *routing*: classify the input, then send it to a specialised follow-up. Their advice is to start from the simplest solution that works.

An OpenCode-based router is buildable, but it gives up the three things this role exists for:

- **Determinism.** An LLM makes the decision.
- **Neutrality.** The brain is tied to one CLI.
- **An in-app audit trail.** The reason lives in an OpenCode session instead of next to the capture.

OpenCode is also the only one of the three without schema-constrained final output: `run --format json` is an event stream, whereas Claude has `--json-schema` and Codex has `--output-schema`. OpenCode is therefore an executor, not the brain.

### Criteria comparison

| Criterion | A. Dart rules + existing enrichment (chosen) | B. Router agent in OpenCode / Claude | C. Framework as a sidecar service | D. Multi-agent GUI |
|---|---|---|---|---|
| User context (vault notes) | Read vault files directly; Obsidian need not be running | Through an Obsidian MCP server | Custom loader | None |
| Deterministic routing | Yes. The LLM only fills closed enums; the rule table decides | No | Partly | Human |
| Triggers / follow-ups | After enrichment, in the app's own queue | External call needed | Separate process and state | Manual |
| Mark done | `isProcessedByUser` + `closures.jsonl` exist | Must call back | Must call back | None |
| What and why | `decisions.jsonl` + `RouteRecord.decision` | Buried in a transcript | Custom log | None |
| Claude / Codex / OpenCode interchangeable | `ProjectAgent` + `promptArguments`; one result channel | One CLI | Wrappers | Partly |
| Cost | S–M, all in this repo | M | L (Python next to Flutter) | S, but misses the requirements |

## Design

### Deterministic means this

```
enrichment (LLM, structured)  → CaptureFacts  {category, project, priority, tags, suggestedRoute}
context files (vault)         → ContextFacts  {priorities, active projects}
device settings               → Environment   {primaryAgent, dispatcherDevice}

decide(CaptureFacts, ContextFacts, Environment, Project) → Decision?   // pure, no IO
Decision {ruleId, action: SuggestedRouteKind (file|command|agent|none), agent?, mode: readOnly|write,
          autonomy: suggest|auto, reason, facts}
```

- **Rule order.** Rules are ordered and the first match wins. They start in code. Later (v4) they can be loaded from an editable rules note.
- **Example rules:**
  - `R10`: `agentTask` on a Command-bound project → `command`
  - `R20`: `agentTask` on a project with a repo → `agent(primaryAgent, readOnly)`
  - `R80`: the model's own `suggestedRoute`, when it is an offered route → that kind (an explicit rule, so every proposal still carries a `ruleId`)
  - `R90`: default → `none`
- **Vocabulary.** `action` reuses the existing `SuggestedRouteKind`, so `file` is the inbox exit. The decision feeds the existing `suggestedRoute` and its card chip, so a card never shows two proposals. A suggestion the user dismissed (`auto=false`) is never overwritten.
- **One predicate.** R10 calls the same check `ProjectCaptureRouter` uses to choose Command, so the chip and `route()` cannot disagree.
- **What determinism covers.** Determinism is over **facts**, not over the raw capture. Re-running enrichment can change `category`, so the log stores the facts themselves, not a hash, and a decision can be replayed.
- **Absent is not empty.** `category == null` (enrichment never ran) yields **no** decision, not `none`.
- **The reason comes from the rule.** It is a template filled with the facts the rule matched on. The model only supplies facts it already produces, such as `category` and `priorityReason`.

### Seams it builds on

| Piece | Where | Change |
|---|---|---|
| Policy | new `lib/features/switchboard/` | `CapturePolicy` interface, `DisabledCapturePolicy` default, rule table in `data/` |
| Current decision point | `recordings/data/command_router.dart:152` | its two branches become R10 / R20-equivalents |
| Suggestion | `recordings/domain/suggested_route.dart` | fed by `Decision` |
| Decision log | new `decisions.jsonl` (append-only, like `triage.jsonl` / `closures.jsonl`) | every decision: none, rejected, shadow and executed |
| Route record | `recordings/domain/route_record.dart` | optional `decision {ruleId, reason, autonomy}`; absent on legacy rows |
| Executor | `projects/data/native_agent_jobs.dart` (prompt through the job's `stdin` file), `projects/domain/agent_session_launcher.dart` (`ProjectAgent`) | `ProjectAgent.opencode` with `promptArguments` and `skipPermissionsArguments` branches |
| Environment | `AgentSettings` (per device, never synced) | `primaryAgent`, `dispatcherDevice`, a per-project override, read through a resolver |
| Result | `.agent-tasks/<id>-result.md` + `AgentArtifactScanner` | the one result channel for every CLI. CLI JSON is used only for exit status and session id |
| Done | `RecordingsController.route()`, `toggleProcessed`, `ClosureLog` | unchanged semantics, see below |

### Executor arguments

The prompt is **fixed**: "carry out the brief in `.agent-tasks/<id>.md`, write the result to `-result.md`". It goes through stdin, as today.

- The capture text stays in the brief behind the `BEGIN/END CAPTURE TEXT` fence. It is never placed in a system prompt.
- The working directory comes from `Process.start(workingDirectory:)`.

Per CLI:

- **Claude Code:** `claude -p --output-format json --permission-mode <explicit> --allowedTools <list>`.
  - Since v2.1.302, `-p` starts in Manual mode, so permissions must be set explicitly.
  - Avoid `--bare`. It needs an API key, not the subscription login.
- **Codex:** `codex exec --json -s read-only|workspace-write -o <last-message> -`. Requires a git repo and defaults to read-only.
- **OpenCode:** `opencode run --format json --agent <name> --title capture-<id> --archived`, with `--auto` optional. It has no `--dir` flag. Checked against v2.3.2.

`AGENTS.md` is the shared project context. Codex and OpenCode read it natively. Claude Code reads it only when there is no `CLAUDE.md`, so add `@AGENTS.md` there.

### User context

- **v0/v1: read files directly.** This needs neither Obsidian nor MCP. Inputs:
  - the existing soul (`soulPath`)
  - a configurable *priorities note* path next to it
  - optionally, a glob of project notes whose frontmatter carries rank and status
  The layout of any particular vault is configuration, not code.
- **Later: pass an Obsidian MCP server to the spawned agent.** Use `--mcp-config` for Claude, `codex mcp` or `opencode mcp`. File-based servers (`obsidian-mcp`, basic-memory) work without Obsidian running; the Local REST API plugin does not.

### Done

- **Done at dispatch.** `route()` already takes the capture off the desk.
- **Back on the desk on failure.** It returns when `RouteOutcome` comes back failed or blocked, or when the job exits with an error, and that event is logged to `closures.jsonl`. The alternative, done only on success, is safer, but the desk then fills with work in progress (Q2).

### Two risks that gate auto-launch

1. **Trust boundary.** `docs/architecture/agent-handoff.md:85` says the `agent` suggestion never launches a session itself, and capture text is untrusted (prompt injection). Write-capable auto-launch crosses that line. It is therefore staged, and that document changes in the same PR that lifts the line.
2. **Double dispatch via sync.** Captures sync between devices, and calling `route()` twice appends a second route. Two signed-in devices, or a restart mid-dispatch, could each launch an agent. The guards:
   - a single device has `dispatcherDevice=true`
   - the decision is **persisted before anything is spawned** (persist-before-process, applied to dispatch)
   - before acting, check whether an agent route already exists for the capture (idempotent per `capture_id`, as Command already is)

The policy never touches `status` or a source file, and a policy failure never fails a capture (the best-effort sink contract).

## Rollout

| Stage | Scope | Autonomy | Acceptance |
|---|---|---|---|
| v0: shadow | policy, rule table, `decisions.jsonl`, `RouteRecord.decision`, card chip; accept through HandoffSheet | suggest | one test per rule; same facts give the same `ruleId`; null category gives no decision; legacy JSON loads |
| v1: context + OpenCode | priorities note into `ContextFacts`; `ProjectAgent.opencode`; `primaryAgent` in Config | suggest | parser test on a fixture; OpenCode launched from HandoffSheet on the Linux host |
| v2: auto for safe exits | inbox, Command brief, **read-only** agent on the dispatcher device. Read-only is not safe on its own: an injected capture can still ask to read `.env` or reach the network, so the run gets restricted tools and a network-less sandbox | auto, opt-in per project | dispatching twice yields one job; restart mid-dispatch; failure returns the capture to the desk |
| v3: write-capable launch | agent in a worktree, `workspace-write` / `acceptEdits`, budget and timeout limits | auto, separate opt-in per project and per rule | `agent-handoff.md` updated; injection test against the capture-text fence |
| v4: optional | rules in an editable note, ACP session view, Obsidian MCP for spawned agents | – | – |

## Names considered

`Router`, `Triage`, `Command`, `Handoff` and `Dispatch` are already used in `lib/` and `docs/`. Conductor is a competing product.

- **Switchboard (chosen).** A switchboard connects every call to the right line from a fixed board. That matches deterministic switching to an agent and the Processing Console vocabulary, and it reads well as `SWITCHBOARD → Codex (R20)`.
- **Pointsman.** Sets the track, then the train runs on its own.
- **Docket.** Every capture gets an entry saying what happens next and why. This stresses the log more than the switching.
- **Foreman.** Assigns work and checks it is finished. It implies supervision, which we want to avoid.
- **Marshal.** As in a marshalling yard. It collides with *marshal* in the serialisation sense.

## Open questions (defaults apply)

- **Q1.** Should write-capable agents ever auto-launch? Default: not until v2 has run in shadow for a week.
- **Q2.** Is a capture done at dispatch or at success? Default: at dispatch, and it returns to the desk on failure.
- **Q3.** Which device dispatches? Default: the Linux host.
- **Q4.** Name? Default: Switchboard.

## Sources

- Anthropic, Building effective agents — https://www.anthropic.com/engineering/building-effective-agents
- LangGraph workflows and agents — https://docs.langchain.com/oss/python/langgraph/workflows-agents
- OpenAI Agents SDK handoffs — https://openai.github.io/openai-agents-python/handoffs/
- Google ADK workflow agents — https://adk.dev/agents/workflow-agents/
- Mastra agents vs workflows — https://mastra.ai/learn/agents-vs-workflows
- Claude Agent SDK hooks — https://code.claude.com/docs/en/agent-sdk/hooks
- ACP agents — https://agentclientprotocol.com/get-started/agents.md
- Claude Code headless / subagents / memory — https://code.claude.com/docs/en/headless, https://code.claude.com/docs/en/sub-agents, https://code.claude.com/docs/en/memory
- Codex non-interactive mode / AGENTS.md — https://learn.chatgpt.com/docs/non-interactive-mode, https://learn.chatgpt.com/docs/agent-configuration/agents-md
- OpenCode CLI / agents / server — https://opencode.ai/docs/en/cli, https://opencode.ai/docs/agents/, https://opencode.ai/docs/server/
- Vibe Kanban shutdown — https://vibekanban.com/shutdown
- Obsidian Local REST API — https://github.com/coddingtonbear/obsidian-local-rest-api
- basic-memory — https://github.com/basicmachines-co/basic-memory
- obsidian-mcp (Rust) — https://docs.rs/crate/obsidian-mcp/2.2.1
- Durable execution on SQLite — https://hackernoon.com/you-dont-need-temporal-yet-durable-execution-for-ai-agents-in-150-lines

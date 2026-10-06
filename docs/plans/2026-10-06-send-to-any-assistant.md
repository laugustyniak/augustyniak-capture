# Plan: send any capture to any assistant

Status: **proposed** · Owner: laugustyniak · Issue: #244 · Scope: one **Send
to…** sheet that delivers a capture to Claude, ChatGPT, Perplexity, Gemini or
any other assistant, through the browser, the system share sheet, the
clipboard, or a terminal session on macOS, Linux and Windows — with or without a
project.

## Motivation

A capture leaves the queue today in three ways, all of them through a project
(`docs/architecture/agent-handoff.md`):

- appended to the project's `inbox.md` (`ProjectInboxRouter`);
- opened as a local coding-agent session — Ghostty or a Linux terminal, Zellij,
  and one of `codex | claude | agy` (`ProjectAgentHandoff`);
- filed as a brief with a Command host (`CommandRouter`).

What that leaves out:

1. **A capture without a project has no way out.** `ProjectAgentHandoff._resolve`
   answers null for a missing project, a project with no `repoPath` and a
   Command-bound project, so `agentsFor` is empty and the queue hides the agent
   button. Most of what gets dictated is a question for an assistant, not a task
   for a repository.
2. **No web path.** ChatGPT, Claude.ai, Perplexity and Gemini in the browser
   are unreachable from the app, and on a machine without the CLIs installed
   that is the only assistant there is.
3. **No system share sheet.** `share_plus` is not a dependency. On a phone the
   share sheet is the simplest way into every assistant app the user has
   installed, including ones this app has never heard of.
4. **Windows is refused deliberately.** `TerminalLauncher.isSupportedPlatform`
   is `isMacOS || isLinux`, because the session model — attach an existing
   session or start one from a layout — is Zellij's, and Zellij has no Windows
   build.
5. **No Gemini CLI.** `AgentKind` / `ProjectAgent` know `codex`, `claude`
   and `agy`.
6. **Copy is not part of any send flow.** It exists as a button in the focus
   view (`capture_focus_view.dart`), not as the fallback every other path can
   rely on.

## What does not change

- **Persist before process is untouched.** Sending is an action on a
  captured row, minutes or days after it is on disk. Nothing here runs inside
  a capture entry point.
- **The Zellij launcher keeps its behaviour on macOS and Linux**, including
  `attachedToExistingSession` and the brief written to `.agent-tasks/`.
- **A Command-bound project still routes `agentTask` captures to Command.**
  The new sheet does not offer a local terminal for a bound project, for the
  reason `_resolve` already documents. Web, share and copy *are* offered: they
  answer a different question ("ask an assistant about this") from Command's
  ("plan and execute work in this repo").
- **`renderCaptureBrief` stays the only brief format.** The web and share
  paths send the prompt, not the brief: front matter is noise in a chat box.
- **The capture's text never passes through a shell string.** Every new path
  hands it over as a URL query parameter, a share intent payload, the clipboard,
  or a file the launched process reads itself.

## Design

### One sheet, three kinds of target

`HandoffSheet` becomes the **Send to…** sheet. It keeps the editable prompt
field (seeded from the prompt builder below) and replaces the agent chips with
grouped targets:

| Group | Targets | Available when |
| --- | --- | --- |
| Terminal | Claude Code, Codex, Gemini CLI, Antigravity | desktop, a terminal resolves, project not Command-bound |
| Web | Claude, ChatGPT, Perplexity, Gemini | always (`url_launcher` exists on every platform) |
| Share | system share sheet | `share_plus` supports the platform (Android, iOS, macOS; Windows and Linux shown only if verified useful) |
| Copy | copy prompt | always |

Because Web and Copy are always available, **the button is shown on every
capture with text**, project or not. That reverses the "hidden rather than
disabled" rule only in the sense that there is always something to do; a
capture with no text at all (audio still transcribing) keeps the button hidden.

The keyboard binding stays `A`. The previously chosen target is remembered per
device (`AppSettings.lastSendTarget`, omitted from JSON when absent) and
preselected; a project's `defaultAgent` still wins for terminal targets.

### Prompt builder moves to the domain

`promptFor` lives on `ProjectAgentHandoff` today, so `DisabledAgentHandoff`
answers `''` and a projectless capture has no prompt at all. It moves to a
pure function `capturePrompt(RoutedCapture)` in
`recordings/domain/capture_prompt.dart` with the same rules (body, then
summary, then title). `AgentHandoff.promptFor` delegates to it so the existing
seam and its tests stay valid.

### Web targets

`WebAssistant` enum in `recordings/domain/web_assistant.dart`, one definition
per service:

| Value | Prefill URL | `supportsPrefill` |
| --- | --- | --- |
| `claude` | `https://claude.ai/new?q=<prompt>` | true |
| `chatgpt` | `https://chatgpt.com/?q=<prompt>` | true |
| `perplexity` | `https://www.perplexity.ai/search?q=<prompt>` | true |
| `gemini` | `https://gemini.google.com/app` | false |

None of these query parameters is a documented API. Keeping them in one enum
means a service that drops prefill is a one-line change to `supportsPrefill`,
not a hunt through the UI.

`WebAssistantSender` (`recordings/data/web_assistant_sender.dart`):

1. Build the URL with `Uri.https(..., {'q': prompt})` — never string
   concatenation, so encoding is the URI class's job.
2. If `!supportsPrefill`, or the encoded URL is longer than
   `maxPrefillUrlLength` (initial value 6000 characters, set by the spike), copy
   the prompt to the clipboard and open the bare page. The sheet then shows
   "Prompt copied — paste it into <service>". **A long transcript is never
   silently truncated by a URL limit.**
3. `launchUrl(uri, mode: LaunchMode.externalApplication)`. On a phone with the
   assistant's app installed, Android App Links and iOS Universal Links may
   open the app instead of the browser; that is acceptable and probably
   preferred.
4. A `false` from `launchUrl` throws `WebAssistantUnavailableException`, which
   leaves the capture exactly as it was.

The sheet shows the destination domain before the user confirms. Sending to a
web assistant publishes the capture's text to a third party; the user should
see where it goes on the button itself, not discover it afterwards.

### Share and copy

`ShareSender` wraps `SharePlus.instance.share(ShareParams(text: prompt,
subject: title))`. On Android and iOS it reports `ShareResultStatus`; on the
other platforms the result is `unavailable`, which is treated as "opened, not
confirmed".

Copy uses `Clipboard.setData` and is the fallback every other sender reaches
for, so it lives in one place (`CopySender`) instead of being re-implemented
in the web sender.

### Recording what happened

Delivery-first still holds, but web, share and copy **cannot confirm
delivery**: `launchUrl` returning true means a browser opened, not that a
prompt was sent. So:

- New `RouteKind.assistant`. `RouteRecord.target` is
  `<service> · web`, `share` or `clipboard`. On Android/iOS a share whose
  status is `dismissed` records nothing.
- The route **is** recorded on success of the local step (URL opened, share
  sheet completed, clipboard written), so the capture says where it was sent.
- The capture is **not** closed automatically. After a web, share or copy send
  the sheet stays open with **Mark done** and **Keep on desk**. Mark done
  calls the existing close path with `ClosureKind.handoff`. Keep on desk closes
  only the sheet.
- Terminal sends keep today's semantics: `RouteKind.agent`, closed on a new
  session, sheet left open on `attachedToExistingSession`.

`RouteKind.fromName` already drops an unknown kind, so an older build loses an
`assistant` row — the same cost `command` was accepted at, and stated for the
same reason.

`RecordingsController` gains `send(String id, SendTarget target, String
prompt)` beside `handoff`, sharing its single-flight set
(`_handoffsInProgress`) so a double tap does not open two tabs.

### Terminal session without a project

`ProjectAgentHandoff` grows a second resolution: no project (or a project with
no `repoPath`, still not Command-bound) resolves to a **scratch workspace**
`<appSupport>/sessions/<capture-id>/`:

- created on first send, never deleted by the app (an agent may have written
  results into it; the same reason `.agent-tasks/` is append-only);
- the brief is written there as `brief.md` with `renderCaptureBrief`;
- the Zellij session name is derived from the capture id instead of the
  project name, so two projectless captures do not attach to each other.

`AgentArtifactScanner` learns the scratch directory as a third root so whatever
the agent writes there shows up on the card like a `.agent-tasks` result.

### Gemini CLI

`AgentKind.gemini` and `ProjectAgent.gemini('gemini')`, with
`promptArguments` → `['-i', safe]` (interactive with an opening prompt) and
`skipPermissionsArguments` → `['--yolo']`. Both spellings are verified against
the installed CLI's `--help` in slice 2 before they are written down, the way
Codex's was. An older build reading a project whose `defaultAgent` is
`gemini` gets null from `AgentKind.fromName`, which already degrades to no
default.

### Windows terminal

`WindowsTerminalLauncher` implements `TerminalLauncher` and makes
`isSupportedPlatform` true on Windows. It does not use Zellij, because there
is none, so it is a second `AgentSessionLauncher` rather than a third
`TerminalLauncher` under the Zellij one:

1. Write `prompt.txt` (UTF-8) and `launch.ps1` next to the brief.
2. `launch.ps1` resolves the CLI and runs it with the prompt read from the
   file:

   ```powershell
   $prompt = Get-Content -Raw -Encoding UTF8 -LiteralPath "$PSScriptRoot\prompt.txt"
   & claude $prompt
   ```

   The CLI name comes from `ProjectAgent.executable`, a controlled value; the
   only interpolated data is the script's own directory.
3. Launch `wt.exe -d <workspace> pwsh -NoProfile -ExecutionPolicy Bypass -File
   launch.ps1`, falling back to `powershell.exe` when `pwsh` is absent and to
   `cmd.exe /c start "" powershell ...` when `wt.exe` is absent.

**The prompt is never an argv element on Windows.** `wt` splits its command
line on `;`, and Windows has no argument vector at all — every process
re-parses one command-line string with its own rules — so a multi-line
dictated note is a quoting bug waiting for its first quote mark. A file read by
the script sidesteps both. The `disarmOptionLookalike` rule still applies
inside the script for the same reason as on POSIX: PowerShell passes `$prompt`
as one argument, and a leading dash would still be parsed as a flag by the CLI.

There is no attach on Windows: every send is a new session, so
`attachedToExistingSession` is always false. `ExecutableResolver` gains a
Windows implementation (`;` separator, `PATHEXT`, `%LOCALAPPDATA%\Programs`,
`%APPDATA%\npm`) since the POSIX one cannot find `claude.cmd`.

## Slices

Each slice is a PR on its own branch, merged `--no-ff`, with tests written
first and seen red.

### Slice 1 — copy, share, web (all platforms, no project needed)

- `capturePrompt` in the domain; `ProjectAgentHandoff.promptFor` delegates.
- `WebAssistant`, `WebAssistantSender`, `ShareSender`, `CopySender`.
- `RouteKind.assistant`, `RecordingsController.send`, Mark done / Keep on desk.
- Sheet regrouped; button shown on every capture with text.
- `share_plus` added to `pubspec.yaml`.

Tests:

- `capture_prompt_test.dart`: body, then summary, then title — moved from
  the existing handoff tests, not duplicated.
- `web_assistant_test.dart`: prefill URL per service; a prompt with `&`, `#`,
  `?`, newlines and Polish characters round-trips through `Uri.queryParameters`;
  over the limit falls back to clipboard + bare page; Gemini always falls back.
- `route_record_test.dart`: `assistant` round-trips; legacy JSON unchanged.
- Controller: a failed launch records nothing and leaves the capture open;
  a successful web send records the route and does **not** set
  `isProcessedByUser`; Mark done does.
- Widget test for the sheet: projectless capture shows Web and Copy and no
  Terminal group.
- Run it and look: send a real capture to each of the four services on Linux
  and Android; screenshot the sheet in both themes.

### Slice 2 — terminal session without a project, Gemini CLI

- Scratch workspace resolution, session name from capture id, scanner root.
- `AgentKind.gemini`, `ProjectAgent.gemini`, verified flag spellings.

Tests: `_resolve` answers the scratch workspace for no project and for an
empty `repoPath`, and still answers nothing for a Command-bound project; two
projectless captures get distinct session names; `AgentKind.fromName('gemini')`
on the legacy path; `promptArguments` for Gemini disarms a leading dash.

### Slice 3 — Windows

- `WindowsTerminalLauncher`, the script writer, `WindowsExecutableResolver`.
- `isSupportedPlatform` true on Windows; `UnsupportedTerminalLauncher` kept for
  everything else.
- Update the "Windows is refused deliberately" paragraph in
  `docs/architecture/agent-handoff.md`.

Tests: the generated `launch.ps1` contains no capture text; `prompt.txt` holds
the prompt byte for byte; argument vector for `wt` with and without `pwsh`;
resolver finds `claude.cmd` through `PATHEXT`. Manual check on a real Windows
machine — CI builds Windows but runs no session.

## Spike before slice 1

Half a day, no code merged:

1. Does `claude.ai/new?q=` still prefill, and does it send or only fill the
   box? Same for `chatgpt.com/?q=` (historically sends immediately) and
   Perplexity. If one sends immediately, the sheet says so on its button.
2. The longest prompt each service accepts through `?q=`, to set
   `maxPrefillUrlLength`.
3. Whether Gemini has gained a prefill parameter.
4. On Android: does `chatgpt.com/?q=` open the ChatGPT app with the prompt,
   or the app without it? If the app drops the query, web targets on Android
   should prefer share.
5. `share_plus` on Linux and Windows: does it do anything useful, or should
   Share be hidden there?

Results go into this file under **Spike results** before slice 1 starts.

## Open questions

- Should a per-project "default assistant" exist next to `defaultAgent`, or is
  the per-device last choice enough? Proposed: per-device only, until someone
  asks.
- A prompt template ("Answer in Polish", "Be concise") per web target. Out of
  scope; the editable prompt field covers it today.

# MCP server

A local, **read-only** [MCP](https://modelcontextprotocol.io) server that lets a coding agent (Claude Code, Codex, Gemini CLI) search and read the user's captures. Read this before touching `bin/capture_mcp.dart` or `features/mcp/`.

It is a separate binary, not part of the Flutter app: the agent host launches it over stdio, it answers, and it exits when the host closes the pipe. There is no network listener.

## Layout

- `bin/capture_mcp.dart` — flags, wiring, stdio. Protocol JSON goes to **stdout and nothing else**; diagnostics go to stderr.
- `features/mcp/domain/mcp_server.dart` — newline-delimited JSON-RPC 2.0 over a `Stream<String>` and a sink, so tests drive it without a process. `initialize`, `notifications/*` (no reply), `ping`, `tools/list`, `tools/call`. Unknown method is -32601, bad params or unknown tool -32602, an unparseable line -32700 — and the loop carries on.
- `features/mcp/domain/capture_tools.dart` — the three tools and their JSON Schemas. A failure *inside* a tool (no database, unknown id or project) is a result with `isError: true`, so the model can read it.
- `features/mcp/data/sqlite_capture_source.dart` — the reader. `default_paths.dart` — where the files are.

**No `package:flutter` anywhere in that graph, transitively.** The binary is built with plain `dart`, which cannot link `dart:ui`. That is why the reader does not reuse `RecordingsRepository` (it reaches `core/database/app_database.dart`, which calls `debugPrint`) and re-implements the read rules by hand; it does reuse the pure `Recording` and `Project` domain classes. `test/mcp/mcp_flutter_free_test.dart` walks the import graph and fails on the first `package:flutter`.

## The read-only guarantee

The database is opened with `OpenMode.readOnly`, per tool call, and closed again. Nothing is cached, because the app keeps writing while the host holds the server open. The app runs WAL, so the reader neither blocks the writer nor sees an uncommitted row; `test/mcp/capture_reader_test.dart` holds an open `BEGIN IMMEDIATE` transaction on a second connection and reads around it. The server writes nothing — not to the database, not to the recordings folder, not to a repository. There is deliberately no write tool: creating a note or marking a capture routed must go through `RecordingsController`'s entry points, which is a follow-up.

Output carries content only. **No `filePath`, thumbnail, segment or artifact path ever leaves the server**, and neither do bytes; `routes` carry kind, target, time and the outcome's state and PR URL. Keys whose value is absent are omitted rather than sent as `null` (absent and empty are different facts). Discarded and deleted captures have no row, so they are never returned.

## The stale-marker rule

Mirrors `RecordingsRepository.loadAll`: SQLite first; `recordings.json` when the table is empty or the read throws; and **only** `recordings.json` while `recordings.db-stale` exists beside it — the marker means the table is the half that failed to commit, so it holds the *previous* state. An unreadable row is skipped and noted on stderr, never failing the whole read. Unlike the app, the server never backs a file up (`.corrupt-` / `.partial-`): it only reads. Projects come from the `projects` table, then `projects.json`.

## Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `search_captures` | `query` (required), `project?`, `since?` (ISO date), `limit?` (default 20, max 100) | Case-insensitive substring over title, summary, transcript and tags; transcripts cut to ~300 characters |
| `get_capture` | `id` | One capture, full transcript |
| `list_project_captures` | `project`, `status?`, `limit?` | Newest first; `status` is a `RecordingStatus` name |

`project` is an id or a case-insensitive name.

## Paths and flags

| | Default |
| --- | --- |
| Linux database | `${XDG_DATA_HOME:-~/.local/share}/ai.augustyniak.capture/app_database.sqlite` |
| macOS database | `~/Library/Application Support/ai.augustyniak.capture/app_database.sqlite` |
| Recordings dir | `<documents>/recordings` — `XDG_DOCUMENTS_DIR` from `~/.config/user-dirs.dirs` on Linux, `~/Documents` otherwise |

`--db <path>` and `--recordings-dir <path>` override. Any other platform must pass both. The macOS paths are derived from the unsandboxed setup in `docs/platform-setup.md`, not yet checked on a Mac.

## Build and setup

`dart compile exe` refuses packages with build hooks (`sqlite3`), so build a bundle instead:

```bash
dart build cli -t bin/capture_mcp.dart -o build/mcp
# build/mcp/bundle/bin/capture_mcp  +  build/mcp/bundle/lib/libsqlite3.so
```

Keep `bundle/bin` and `bundle/lib` together; the binary finds `libsqlite3` beside it. Then register it with the agent:

```bash
claude mcp add augustyniak-capture -- /path/to/build/mcp/bundle/bin/capture_mcp
```

Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.augustyniak-capture]
command = "/path/to/build/mcp/bundle/bin/capture_mcp"
args = []
```

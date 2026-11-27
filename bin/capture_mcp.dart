import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/decision_store.dart';
import 'package:augustyniak_capture/features/mcp/data/default_paths.dart';
import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/mcp/domain/mcp_server.dart';

/// MCP server over stdio: read-only, plus `submit_decision` (which writes only
/// `decisions/`) with `--allow-decisions`. Protocol JSON goes to stdout and nothing
/// else does; diagnostics go to stderr. See `docs/architecture/mcp.md`.
Future<void> main(List<String> args) async {
  String? db;
  String? recordingsDir;
  bool allowDecisions = false;
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db' when i + 1 < args.length:
        db = args[++i];
      case '--recordings-dir' when i + 1 < args.length:
        recordingsDir = args[++i];
      case '--allow-decisions':
        allowDecisions = true;
      case '--help' || '-h':
        stderr.writeln(
          'usage: capture_mcp [--db <app_database.sqlite>] '
          '[--recordings-dir <dir>] [--allow-decisions]',
        );
        return;
      default:
        stderr.writeln('capture_mcp: unknown argument ${args[i]}');
        exit(64);
    }
  }

  final CapturePaths paths;
  try {
    paths = CapturePaths.resolve(db: db, recordingsDir: recordingsDir);
  } on ArgumentError catch (e) {
    stderr.writeln('capture_mcp: ${e.message}');
    exit(64);
  }
  // Beside the database, where the app looks for it.
  final String decisionsDir = '${File(paths.dbPath).parent.path}/decisions';
  stderr.writeln(
    'capture_mcp: db=${paths.dbPath} recordings=${paths.recordingsDir} '
    'decisions=$decisionsDir allow-decisions=$allowDecisions',
  );

  void log(String m) => stderr.writeln('capture_mcp: $m');
  final McpServer server = McpServer(
    CaptureTools(
      SqliteCaptureSource(
        dbPath: paths.dbPath,
        recordingsDir: paths.recordingsDir,
        log: log,
      ),
      decisions: DecisionStore(directory: decisionsDir, log: log),
      allowDecisions: allowDecisions,
      log: log,
    ),
    log: log,
  );
  await server.serveBytes(stdin, stdout.writeln);
}

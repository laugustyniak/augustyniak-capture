import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/default_paths.dart';
import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_tools.dart';
import 'package:augustyniak_capture/features/mcp/domain/mcp_server.dart';

/// Read-only MCP server over stdio. Protocol JSON goes to stdout and nothing
/// else does; diagnostics go to stderr. See `docs/architecture/mcp.md`.
Future<void> main(List<String> args) async {
  String? db;
  String? recordingsDir;
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db' when i + 1 < args.length:
        db = args[++i];
      case '--recordings-dir' when i + 1 < args.length:
        recordingsDir = args[++i];
      case '--help' || '-h':
        stderr.writeln(
          'usage: capture_mcp [--db <app_database.sqlite>] '
          '[--recordings-dir <dir>]',
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
  stderr.writeln(
    'capture_mcp: db=${paths.dbPath} recordings=${paths.recordingsDir}',
  );

  void log(String m) => stderr.writeln('capture_mcp: $m');
  final McpServer server = McpServer(
    CaptureTools(
      SqliteCaptureSource(
        dbPath: paths.dbPath,
        recordingsDir: paths.recordingsDir,
        log: log,
      ),
      log: log,
    ),
    log: log,
  );
  await server.serveBytes(stdin, stdout.writeln);
}

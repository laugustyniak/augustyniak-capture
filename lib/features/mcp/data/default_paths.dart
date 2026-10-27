import 'dart:io';

import 'package:path/path.dart' as p;

/// Bundle id of the app; the data directory is named after it on Linux and
/// macOS (`getApplicationSupportDirectory`).
const String _appId = 'ai.augustyniak.capture';

class CapturePaths {
  const CapturePaths({required this.dbPath, required this.recordingsDir});

  final String dbPath;
  final String recordingsDir;

  /// Flags win; otherwise the platform defaults the app itself resolves.
  ///
  /// Linux: `$XDG_DATA_HOME/ai.augustyniak.capture/app_database.sqlite` and
  /// `$XDG_DOCUMENTS_DIR/recordings`. macOS runs unsandboxed, so the database
  /// is under `~/Library/Application Support/ai.augustyniak.capture` and the
  /// recordings under `~/Documents/recordings`. Any other platform must pass
  /// both flags.
  factory CapturePaths.resolve({
    String? db,
    String? recordingsDir,
    Map<String, String>? environment,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String? home = env['HOME'];
    String? defaultDb;
    String? defaultRecordings;
    if (home != null && (Platform.isLinux || Platform.isMacOS)) {
      if (Platform.isMacOS) {
        defaultDb = p.join(
          home,
          'Library',
          'Application Support',
          _appId,
          'app_database.sqlite',
        );
      } else {
        final String dataHome = (env['XDG_DATA_HOME'] ?? '').isNotEmpty
            ? env['XDG_DATA_HOME']!
            : p.join(home, '.local', 'share');
        defaultDb = p.join(dataHome, _appId, 'app_database.sqlite');
      }
      defaultRecordings = p.join(
        _documentsDir(home, env, linux: Platform.isLinux),
        'recordings',
      );
    }
    final String? resolvedDb = db ?? defaultDb;
    final String? resolvedRecordings = recordingsDir ?? defaultRecordings;
    if (resolvedDb == null || resolvedRecordings == null) {
      throw ArgumentError(
        'No default location on this platform; pass --db <path> and '
        '--recordings-dir <path>.',
      );
    }
    return CapturePaths(dbPath: resolvedDb, recordingsDir: resolvedRecordings);
  }

  static String _documentsDir(
    String home,
    Map<String, String> env, {
    required bool linux,
  }) {
    if (linux) {
      final String configHome = (env['XDG_CONFIG_HOME'] ?? '').isNotEmpty
          ? env['XDG_CONFIG_HOME']!
          : p.join(home, '.config');
      final File file = File(p.join(configHome, 'user-dirs.dirs'));
      if (file.existsSync()) {
        final RegExpMatch? match = RegExp(
          r'^XDG_DOCUMENTS_DIR="?([^"\n]+)"?',
          multiLine: true,
        ).firstMatch(file.readAsStringSync());
        if (match != null) {
          return match.group(1)!.replaceAll(r'$HOME', home);
        }
      }
    }
    return p.join(home, 'Documents');
  }
}

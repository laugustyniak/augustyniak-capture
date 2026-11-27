import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../recordings/domain/agent_decision.dart';

/// The `decisions/` directory beside the app database: where the MCP server
/// leaves an agent's decision for the app to apply.
///
/// This is the only thing the server ever writes. It is a plain directory the
/// app also reads, so a symlinked one is refused rather than followed: a link
/// would let a decision file land (or be read) outside the app's data
/// directory. No `package:flutter` here, see `docs/architecture/mcp.md`.
class DecisionStore {
  DecisionStore({required this.directory, void Function(String)? log})
    : _log = log ?? ((String _) {});

  final String directory;
  final void Function(String) _log;

  /// A decision file is a few hundred bytes; anything bigger is not one.
  static const int maxFileBytes = 64 * 1024;

  bool get _isLink => FileSystemEntity.isLinkSync(directory);

  /// Capture ids that have a decision waiting in `decisions/*.json`.
  ///
  /// Fails open: a missing directory, an unreadable, oversize or malformed file
  /// hides nothing (and is logged), because hiding a capture the app will never
  /// apply a decision for would lose it from the queue. `rejected/` and `.tmp`
  /// files are not pending.
  Future<Set<String>> pendingCaptureIds() async {
    final Set<String> ids = <String>{};
    if (_isLink) {
      _log('decisions directory is a symlink; ignored');
      return ids;
    }
    final Directory dir = Directory(directory);
    if (!dir.existsSync()) return ids;
    try {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          if (e.lengthSync() > maxFileBytes) {
            _log('decision file too large, ignored: ${_name(e.path)}');
            continue;
          }
          final AgentDecision? d = AgentDecision.fromJson(
            jsonDecode(e.readAsStringSync()),
          );
          if (d == null) {
            _log('decision file invalid, ignored: ${_name(e.path)}');
          } else {
            ids.add(d.captureId);
          }
        } catch (error) {
          _log('decision file unreadable, ignored: ${_name(e.path)}: $error');
        }
      }
    } on FileSystemException catch (error) {
      _log('decisions directory unreadable: $error');
    }
    return ids;
  }

  /// Writes [decision] as `<decisionId>.json`, `.tmp` first and then renamed,
  /// so the app never sees half a file. Throws [FileSystemException] when
  /// `decisions/` is a symlink.
  Future<void> submit(AgentDecision decision) async {
    if (_isLink) {
      throw const FileSystemException('decisions directory is a symlink');
    }
    final Directory dir = Directory(directory)..createSync(recursive: true);
    final File tmp = File('${dir.path}/${decision.decisionId}.json.tmp');
    tmp.writeAsStringSync(jsonEncode(decision.toJson()), flush: true);
    tmp.renameSync('${dir.path}/${decision.decisionId}.json');
  }

  /// A random UUID v4, which is what the app's drainer accepts as a file name.
  static String newDecisionId() {
    final Random random = Random.secure();
    final List<int> b = List<int>.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final String h = b
        .map((int v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  static String _name(String path) => path.split(Platform.pathSeparator).last;
}

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../logs/domain/log_event.dart';
import '../domain/agent_decision.dart';

/// Applies the decision files an external agent left in `decisions/`, written
/// by the MCP server's `submit_decision`.
///
/// Shaped like `InboxDrainer`, with one difference in what a refusal means.
/// The directory is writable by any local process, so every file is untrusted:
/// a file that is not a valid decision for its own name, or that the
/// controller rejects, moves to `rejected/<name>` with a `<uuid>.reason.txt`
/// and never loops. A file is deleted only after [apply] reports it applied
/// or already closed; a throw (a write that did not land) keeps it for the
/// next pass. The drainer never touches the recordings index: [apply] is the
/// controller's, the only writer.
class DecisionDrainer {
  DecisionDrainer({
    required this.directory,
    required this.apply,
    required LogSink logSink,
  }) : _logSink = logSink;

  final Directory directory;
  final Future<DecisionOutcome> Function(AgentDecision) apply;
  final LogSink _logSink;

  static const int maxFileBytes = 64 * 1024;
  static const String _rejectedDir = 'rejected';

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  bool _draining = false;

  /// Returns how many decisions were applied or found already closed. A call
  /// made while another drain is running returns 0 rather than racing it.
  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    try {
      return await _drain();
    } finally {
      _draining = false;
    }
  }

  Future<int> _drain() async {
    if (!await directory.exists()) return 0;
    final List<(File, DateTime)> files = <(File, DateTime)>[];
    try {
      await for (final FileSystemEntity e in directory.list(
        followLinks: false,
      )) {
        // A symlink is listed as a Link, so it is kept out of the "plain file"
        // branch and refused below.
        if (e is Directory || p.extension(e.path) != '.json') continue;
        try {
          files.add((
            File(e.path),
            (await e.stat()).modified, // stat, not lastModified: no follow
          ));
        } on FileSystemException catch (exception) {
          _log('Decision entry skipped: ${p.basename(e.path)} · $exception');
        }
      }
    } on FileSystemException catch (exception) {
      _log('Decisions unreadable: $exception');
      return 0;
    }
    files.sort(
      ((File, DateTime) a, (File, DateTime) b) => a.$2.compareTo(b.$2),
    );

    int done = 0;
    for (final (File file, _) in files) {
      try {
        if (await _one(file)) done++;
      } catch (exception) {
        _log(
          'Decision not applied, kept: ${p.basename(file.path)} · $exception',
        );
      }
    }
    return done;
  }

  /// True when the file was applied or already closed.
  Future<bool> _one(File file) async {
    final String name = p.basename(file.path);
    final String id = p.basenameWithoutExtension(name);
    if (!_uuid.hasMatch(id)) {
      await _reject(file, 'file name is not a uuid');
      return false;
    }
    if (await FileSystemEntity.isLink(file.path)) {
      await _reject(file, 'symlinks are refused');
      return false;
    }
    if (await file.length() > maxFileBytes) {
      await _reject(file, 'file is larger than $maxFileBytes bytes');
      return false;
    }
    final AgentDecision? decision;
    try {
      decision = AgentDecision.fromJson(
        jsonDecode(utf8.decode(await file.readAsBytes())),
      );
    } on FormatException {
      await _reject(file, 'not valid JSON');
      return false;
    }
    if (decision == null) {
      await _reject(file, 'not a valid decision');
      return false;
    }
    if (decision.decisionId.toLowerCase() != id.toLowerCase()) {
      await _reject(file, 'decisionId does not match the file name');
      return false;
    }

    final DecisionOutcome outcome = await apply(decision);
    if (outcome.kind == DecisionOutcomeKind.rejected) {
      await _reject(file, outcome.reason ?? 'rejected');
      return false;
    }
    await file.delete();
    return true;
  }

  /// Moves [file] out of the watched directory with the [reason] beside it.
  /// A failed move keeps the file: a refusal never deletes anything.
  Future<void> _reject(File file, String reason) async {
    final String name = p.basename(file.path);
    final Directory rejected = Directory(p.join(directory.path, _rejectedDir));
    await rejected.create(recursive: true);
    final String base = p.basenameWithoutExtension(name);
    // Reason first: if the move then fails the file stays and is retried,
    // while a moved file with no reason would be unexplained.
    await File(
      p.join(rejected.path, '$base.reason.txt'),
    ).writeAsString('$reason\n');
    await file.rename(p.join(rejected.path, name));
    _log('Decision $name rejected: $reason');
  }

  void _log(String message) {
    try {
      _logSink.log(message, level: LogLevel.warn);
    } catch (_) {
      // Best-effort sink: never fail a drain.
    }
  }
}

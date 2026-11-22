import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/decision.dart';
import '../domain/decision_log.dart';

/// Every decision, one JSON object per line in `decisions.jsonl`.
///
/// Appended, never rewritten, like `triage.jsonl`: a torn last line costs that
/// line only. Local to the device and kept apart from `recordings.json`, so the
/// log can never reach the index.
class FileDecisionLog implements DecisionLog {
  FileDecisionLog({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'recordings'),
  );

  /// The rows in [raw], skipping any line that is not a JSON object.
  static List<Map<String, dynamic>> parse(String raw) {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final Object? json = jsonDecode(line);
        if (json is Map<String, dynamic>) rows.add(json);
      } catch (_) {
        // A torn line from a kill mid-append; every other row still counts.
        continue;
      }
    }
    return rows;
  }

  @override
  Future<void> append({
    required DateTime at,
    required String captureId,
    required Decision decision,
    required bool applied,
    String? skipReason,
  }) async {
    final Directory directory = await _directory();
    if (!await directory.exists()) await directory.create(recursive: true);
    final Map<String, dynamic> row = <String, dynamic>{
      'at': at.toIso8601String(),
      'captureId': captureId,
      'ruleId': decision.ruleId,
      'kind': decision.kind.name,
      'reason': decision.reason,
      'applied': applied,
      'skipReason': ?skipReason,
      'facts': decision.facts.toJson(),
    };
    await File(p.join(directory.path, 'decisions.jsonl')).writeAsString(
      '${jsonEncode(row)}\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }
}

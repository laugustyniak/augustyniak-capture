import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/daily_triage.dart';

/// Triage digests and decisions, one JSON object per line in `triage.jsonl`.
///
/// Appended, never rewritten, for the reason `closures.jsonl` is: a rejected
/// proposal is the only record that it was rejected, and a store rewritten in
/// one go can lose all of them to a single bad write. A torn last line costs
/// that line only. Kept apart from `recordings.json` so triage can never
/// reach the index.
class FileTriageLog implements TriageLog {
  FileTriageLog({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'recordings'),
  );

  static TriageHistory parse(String raw) {
    final List<TriageDigest> digests = <TriageDigest>[];
    final List<TriageDecision> decisions = <TriageDecision>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final Object? json = jsonDecode(line);
        if (TriageDigest.fromJson(json) case final TriageDigest digest) {
          digests.add(digest);
        } else if (TriageDecision.fromJson(json)
            case final TriageDecision decision) {
          decisions.add(decision);
        }
      } catch (_) {
        // A torn line from a kill mid-append; every other row still counts.
        continue;
      }
    }
    return TriageHistory.fold(digests: digests, decisions: decisions);
  }

  @override
  Future<TriageHistory> load() async {
    final File file = await _file();
    if (!await file.exists()) return const TriageHistory();
    // A read failure propagates: claiming "nothing rejected" on a failed read
    // would bring every rejected proposal back.
    return parse(await file.readAsString());
  }

  @override
  Future<void> appendDigest(TriageDigest digest) => _append(digest.toJson());

  @override
  Future<void> appendDecision(TriageDecision decision) =>
      _append(decision.toJson());

  Future<void> _append(Map<String, dynamic> row) async {
    final File file = await _file();
    await file.writeAsString(
      '${jsonEncode(row)}\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  Future<File> _file() async {
    final Directory directory = await _directory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return File(p.join(directory.path, 'triage.jsonl'));
  }
}

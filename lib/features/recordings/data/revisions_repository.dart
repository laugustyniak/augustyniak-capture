import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/recording_revision.dart';

/// Append-only change history, one JSON object per line in `revisions.jsonl`,
/// alongside the recordings index.
///
/// **Line-delimited and appended, not rewritten** — the one file in this app
/// that breaks the `.tmp` + `rename` house style, on purpose. Every other store
/// rewrites its whole contents on each change, and that is exactly the shape
/// that let one bad read destroy a whole index (see
/// `RecordingsRepository.loadAll`). A history whose entire job is to preserve
/// overwritten values must not itself be overwritten: `FileMode.writeOnlyAppend`
/// can lose at most the row being written, never a row already on disk.
///
/// The trade-off is a torn final line after a kill mid-write, which [load]
/// absorbs by skipping rows it cannot parse — a strictly better failure than
/// losing the file.
///
/// The file is not capped. Every other store here is (logs at 500 rows), but
/// this one holds the only copy of text that has since been overwritten, so
/// trimming it would be the very data loss this feature exists to prevent.
/// [RecordingRevision.maxValueLength] bounds each row instead, and the rule in
/// `RecordingsController` — never record a change out of an empty value — keeps
/// first-time fills, including every transcript, out of the file entirely.
class RevisionsRepository {
  /// Newest first, grouped by capture id. Rows for captures that no longer
  /// exist are kept: the file is a log, and filtering is the caller's business.
  Future<Map<String, List<RecordingRevision>>> load() async {
    final File file = await _file();
    if (!await file.exists()) return <String, List<RecordingRevision>>{};

    final String raw;
    try {
      raw = await file.readAsString();
    } catch (_) {
      // Same contract as `LogStore`: history is supporting evidence, never a
      // precondition. An unreadable file costs the history view, not start-up.
      return <String, List<RecordingRevision>>{};
    }

    final Map<String, List<RecordingRevision>> byRecording =
        <String, List<RecordingRevision>>{};
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final RecordingRevision revision = RecordingRevision.fromJson(
          jsonDecode(line) as Map<String, dynamic>,
        );
        byRecording
            .putIfAbsent(revision.recordingId, () => <RecordingRevision>[])
            .add(revision);
      } catch (_) {
        // A torn last line from a kill mid-append, or a row from a build that
        // wrote a field this one cannot read. Skip it; the rest is still good.
        continue;
      }
    }

    for (final List<RecordingRevision> rows in byRecording.values) {
      rows.sort(
        (RecordingRevision a, RecordingRevision b) => b.at.compareTo(a.at),
      );
    }
    return byRecording;
  }

  /// Serializes appends. `O_APPEND` places every write at the end of the file,
  /// but it does not make a *large* write indivisible — and a row here carries
  /// up to [RecordingRevision.maxValueLength] characters per side, far past any
  /// size the platform writes in one go. Two concurrent appends could therefore
  /// interleave mid-row and produce two corrupt lines out of two good ones.
  ///
  /// That is not hypothetical: the background drain and a hand edit both reach
  /// [RecordingsController] `_update` independently, which is exactly why the
  /// index write has `_saveInFlight`. Same problem, same fix.
  Future<void>? _appendInFlight;

  /// Append [revisions], one line each, in a single write so the batch from one
  /// edit lands together.
  Future<void> append(List<RecordingRevision> revisions) async {
    if (revisions.isEmpty) return;

    while (_appendInFlight != null) {
      // Await, then re-check: another caller may have queued behind the same
      // future while this one was suspended.
      await _appendInFlight;
    }
    final Future<void> mine = _append(revisions);
    _appendInFlight = mine;
    try {
      await mine;
    } finally {
      if (identical(_appendInFlight, mine)) _appendInFlight = null;
    }
  }

  Future<void> _append(List<RecordingRevision> revisions) async {
    final File file = await _file();
    final String payload = revisions
        .map((RecordingRevision revision) => jsonEncode(revision.toJson()))
        .join('\n');
    await file.writeAsString(
      '$payload\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory =
        Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'revisions.jsonl'));
  }
}

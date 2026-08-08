import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/closure_event.dart';

/// Closed captures, one JSON object per line in `closures.jsonl`.
///
/// **Appended, never rewritten** — the third store in this repo to break the
/// house style, alongside `revisions.jsonl` and `focus-sessions.jsonl`, and for
/// the same reason. Every other store rewrites its whole contents on each
/// change, which is precisely the shape that once let a single bad read destroy
/// the recordings index. A tally of work already finished is the only copy of
/// that fact, so the file must not be capable of being written wrong in one go.
/// `FileMode.writeOnlyAppend` can lose at most the row being written.
///
/// **This is also why the count is not derived from `recordings.json`.** That
/// index is rewritten wholesale and *shrinks* on `deleteRecording`, so a history
/// read from it would be silently rewritten by a deletion — and the one bit it
/// holds (`isProcessedByUser`) is state, which cannot answer "how many did I
/// close on Tuesday" however it is read.
///
/// Not capped, unlike `logs.json`. One closure is one short line, and trimming
/// it would throw away exactly the months worth looking back at.
class FileClosureLog implements ClosureLog {
  const FileClosureLog();

  /// The parsing loop, exposed so it can be exercised without a filesystem or a
  /// Flutter binding. Every bug this class can have lives in here, and reaching
  /// it through `path_provider` would need a binding and a mocked documents
  /// directory for no gain — which is why `FileFocusSessionLog` has no test at
  /// all and this one does.
  static List<ClosureEvent> parse(String raw) {
    final List<ClosureEvent> events = <ClosureEvent>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final ClosureEvent? event = ClosureEvent.fromJson(
          jsonDecode(line) as Object?,
        );
        if (event != null) events.add(event);
      } catch (_) {
        // A torn last line from a kill mid-append, or a row from a newer build.
        // Skip it; every other closure in the file is still good.
        continue;
      }
    }
    return events;
  }

  @override
  Future<List<ClosureEvent>> load() async {
    final File file = await _file();
    if (!await file.exists()) return const <ClosureEvent>[];
    // A read failure is deliberately *not* caught here. The controller has to
    // be able to tell "you have closed nothing" from "the file could not be
    // read", and it can only do that if the failure reaches it — the same rule
    // `_indexUnreadable` and `historyUnreadable` encode. Claiming an empty
    // history on the strength of a failed read is a false statement about the
    // user's own work.
    return parse(await file.readAsString());
  }

  @override
  Future<void> append(ClosureEvent event) async {
    final File file = await _file();
    await file.writeAsString(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.writeOnlyAppend,
      // Flushed for the reason the session log is: the moment after finishing
      // something is exactly when a laptop gets closed.
      flush: true,
    );
  }

  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    // Alongside the other stores rather than in a folder of its own, which is
    // what keeps a backup a single directory to copy.
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'closures.jsonl'));
  }
}

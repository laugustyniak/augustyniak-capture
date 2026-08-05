import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/focus_session.dart';

/// Completed focus sessions, one JSON object per line in `focus-sessions.jsonl`.
///
/// **Appended, never rewritten** — the same break from the house style as
/// `revisions.jsonl`, and for the same reason. Every other store here rewrites
/// its whole contents on each change, which is precisely the shape that once let
/// a single bad read destroy the recordings index. A tally of work already done
/// is the only copy of that fact: nothing can reconstruct last Tuesday's four
/// pomodoros, so the file must not be capable of being written wrong in one go.
/// `FileMode.writeOnlyAppend` can lose at most the row being written.
///
/// This is why the count does not live in `settings.json` as an integer per day.
/// That file is rewritten wholesale on every preference change, so one failed
/// load followed by any save — picking a theme would do — would silently replace
/// the history with an empty map.
///
/// Not capped, unlike `logs.json`. A session is one short line and a heavy year
/// is a few thousand of them; trimming it would throw away the only record of
/// exactly the months the user would most want to look back at.
class FileFocusSessionLog implements FocusSessionLog {
  const FileFocusSessionLog();

  @override
  Future<List<FocusSession>> load() async {
    final File file = await _file();
    if (!await file.exists()) return const <FocusSession>[];

    final String raw;
    try {
      raw = await file.readAsString();
    } catch (_) {
      // Same contract as `LogStore`: the history is supporting evidence, never
      // a precondition. An unreadable file costs the panel, not the timer.
      return const <FocusSession>[];
    }

    final List<FocusSession> sessions = <FocusSession>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final FocusSession? session = FocusSession.fromJson(
          jsonDecode(line) as Object?,
        );
        if (session != null) sessions.add(session);
      } catch (_) {
        // A torn last line from a kill mid-append, or a row from a newer build.
        // Skip it; every other day in the file is still good.
        continue;
      }
    }
    return sessions;
  }

  @override
  Future<void> append(FocusSession session) async {
    final File file = await _file();
    await file.writeAsString(
      '${jsonEncode(session.toJson())}\n',
      mode: FileMode.writeOnlyAppend,
      // Flushed because the thing being recorded is that a block of work is
      // over, and the moment after finishing one is exactly when a laptop gets
      // closed.
      flush: true,
    );
  }

  Future<File> _file() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    // Alongside the other stores rather than in a folder of its own: this app
    // keeps everything it owns under one directory, which is what makes a
    // backup a single thing to copy.
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'focus-sessions.jsonl'));
  }
}

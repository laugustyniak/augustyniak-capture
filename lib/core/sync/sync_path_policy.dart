import 'package:path/path.dart' as p;

/// What a row that arrived over the network is allowed to say about the local
/// filesystem: **a file name, never a location.**
///
/// The rule exists because this app acts on the paths its rows carry. A capture
/// is deleted with `RecordingsRepository.deleteArtifacts`, opened with the OS
/// opener (`openSource`), copied into the note vault as an attachment, and an
/// agent artifact is handed straight to `open`. A pulled row used to supply all
/// of those verbatim, so whoever answered the pipeline request chose which
/// local file got deleted, opened or copied out.
///
/// Re-rooting rather than rejecting is what keeps sync working: the file name
/// is the only part of a remote path that still means anything here, since a
/// source pulled down lands in *this* machine's recordings directory.
class SyncPathPolicy {
  const SyncPathPolicy._();

  /// The bare file name inside a remote path, or null when there is none to
  /// trust.
  ///
  /// Split on both separators: the sender chose its own platform, so a Windows
  /// path reaching a Mac must not survive as one long "name" with backslashes
  /// in it.
  static String? localFileName(Object? remote) {
    if (remote is! String) return null;
    final String raw = remote.trim();
    if (raw.isEmpty) return null;
    // A NUL is truncated at by the C layer underneath `dart:io`, so
    // `a.m4a\u0000/etc/passwd` could name one file here and open another.
    if (raw.contains('\u0000')) return null;

    final String name = raw.split(RegExp(r'[/\\]')).last;
    if (name.isEmpty || name == '.' || name == '..') return null;
    return name;
  }

  /// The `json_payload` of a pulled recording, with every path re-rooted, or
  /// null when the row cannot be made safe.
  ///
  /// **The payload has to be sanitised as well as the columns**, and it is the
  /// half that matters: `RecordingsRepository.loadAll` prefers `json_payload`
  /// whenever it parses, so a clean `file_path` column next to a hostile
  /// payload is a fix that changes nothing.
  static Map<String, dynamic>? sanitizePayload(
    Map<String, dynamic> payload, {
    required String recordingsDirectory,
  }) {
    final String? source = localFileName(payload['filePath']);
    // No usable name for the source: there is nothing to point the row at, and
    // keeping the remote path is the whole defect. Drop the row instead.
    if (source == null) return null;

    final Map<String, dynamic> clean = Map<String, dynamic>.of(payload);
    clean['filePath'] = p.join(recordingsDirectory, source);

    final String? poster = localFileName(payload['thumbPath']);
    // A poster is derived and safe to lose — see the `thumbPath` contract —
    // so an unusable one is dropped rather than costing the row.
    clean['thumbPath'] = poster == null
        ? null
        : p.join(recordingsDirectory, poster);

    // The payload is the half `loadAll` prefers, and every segment path is
    // acted on exactly as `filePath` is: deleted, opened, copied into the
    // vault. A segment whose name cannot be trusted is dropped, like a poster;
    // the row itself only falls when segment 0 is unusable, which the `source`
    // check above already covers.
    final Object? rawSegments = payload['segments'];
    if (rawSegments is List) {
      final List<Map<String, dynamic>> segments = <Map<String, dynamic>>[];
      for (final Object? entry in rawSegments) {
        if (entry is! Map<String, dynamic>) continue;
        final String? name = localFileName(entry['filePath']);
        if (name == null) continue;
        segments.add(<String, dynamic>{
          ...entry,
          'filePath': p.join(recordingsDirectory, name),
        });
      }
      clean['segments'] = segments;
    }

    // Artifacts name files in a project repository *on the machine that ran the
    // agent*, and `AgentArtifactViewerModal` passes one to `open`. Nothing here
    // can re-root them into something meaningful, so they do not travel.
    clean['artifacts'] = const <Map<String, dynamic>>[];

    return clean;
  }
}

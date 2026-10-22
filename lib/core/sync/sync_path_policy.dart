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
}

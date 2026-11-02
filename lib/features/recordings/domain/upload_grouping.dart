/// How an import of several picked files lands in the queue.
enum UploadGrouping {
  /// One capture per file, each processed on its own.
  separate,

  /// One capture: the first file is its source, every other file a fragment,
  /// so they share one transcript and one card.
  single,
}

/// Asked once per import of more than one file, with the number of files.
/// Null means the user dismissed the question, which cancels the import the
/// same way a cancelled pick does.
typedef UploadGroupingChooser = Future<UploadGrouping?> Function(int fileCount);

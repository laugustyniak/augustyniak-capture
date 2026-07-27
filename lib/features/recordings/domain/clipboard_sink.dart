/// Write-only seam used by `RecordingsController` to push finished processor
/// output to the system clipboard. Mirrors [LogSink]: it defaults to a no-op so
/// the pure-Dart tests need no Flutter binding, and the real implementation
/// lives in `data/` because only that layer may touch platform channels.
///
/// Like logging, this must never throw into the capture pipeline — a clipboard
/// that refuses the write is not a reason to fail a transcription.
abstract interface class ClipboardSink {
  Future<void> copy(String text);
}

class NoopClipboardSink implements ClipboardSink {
  const NoopClipboardSink();

  @override
  Future<void> copy(String text) async {}
}

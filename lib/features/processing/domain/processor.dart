import 'dart:io';

import '../../recordings/domain/recording.dart';

/// Turns an item's source artifact into text.
///
/// **The rule reviewers must enforce:** a processor only ever *reads* the
/// source file. It must never write to it, move it, or delete it. On failure it
/// throws; the controller catches, marks the item `failed` with an error
/// string, and the source stays on disk, retryable.
abstract interface class Processor {
  Future<String> process(Recording item);
}

/// Text notes: the body written at ingestion already is the extracted text, so
/// "processing" is reading it back. Keeps text items on the exact same
/// persist-then-process path as everything else instead of special-casing them.
class TextPassthroughProcessor implements Processor {
  const TextPassthroughProcessor();

  @override
  Future<String> process(Recording item) async {
    final File file = File(item.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Source file is missing.', item.filePath);
    }
    return file.readAsString();
  }
}

/// Fallback for capture types whose processor needs a dependency this platform
/// or build does not have (OCR on desktop, ffmpeg where it is unavailable).
/// Mirrors `DisabledTranscriptionService`: the item fails cleanly and stays
/// retryable instead of crashing capture.
class UnavailableProcessor implements Processor {
  const UnavailableProcessor(this.reason);

  final String reason;

  @override
  Future<String> process(Recording item) async {
    throw ProcessorNotConfiguredException(reason);
  }
}

class ProcessorNotConfiguredException implements Exception {
  const ProcessorNotConfiguredException(this.reason);

  final String reason;

  @override
  String toString() => 'Processor is not available: $reason';
}

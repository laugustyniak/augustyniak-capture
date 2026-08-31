import 'dart:io';

import '../../recordings/domain/capture_segment.dart';

/// Turns one source artifact into text.
///
/// **The rule reviewers must enforce:** a processor only ever *reads* the
/// source file. It must never write to it, move it, or delete it. On failure it
/// throws; the controller records the failure against that segment, marks the
/// capture `failed`, and the source stays on disk, retryable.
///
/// It takes a [CaptureSegment] rather than a capture because a capture can hold
/// several artifacts of different types — an appended photo on an audio note
/// has to reach the OCR processor, and the registry keys on the segment's type.
abstract interface class Processor {
  Future<String> process(CaptureSegment segment);
}

/// Text notes: the body written at ingestion already is the extracted text, so
/// "processing" is reading it back. Keeps text items on the exact same
/// persist-then-process path as everything else instead of special-casing them.
class TextPassthroughProcessor implements Processor {
  const TextPassthroughProcessor();

  @override
  Future<String> process(CaptureSegment segment) async {
    final File file = File(segment.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Source file is missing.', segment.filePath);
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
  Future<String> process(CaptureSegment segment) async {
    throw ProcessorNotConfiguredException(reason);
  }
}

class ProcessorNotConfiguredException implements Exception {
  const ProcessorNotConfiguredException(this.reason);

  final String reason;

  @override
  String toString() => 'Processor is not available: $reason';
}

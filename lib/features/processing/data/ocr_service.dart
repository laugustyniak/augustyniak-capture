import 'dart:io';

import '../domain/processor.dart';

/// Extracts text from an image file. The OCR analogue of `TranscriptionService`:
/// swappable, and a disabled/unconfigured impl degrades cleanly instead of
/// crashing capture.
abstract interface class OcrService {
  /// Reads [image] and returns recognized text. Must never mutate or delete the
  /// source. Throws on failure (caught by the controller → status `failed`).
  Future<String> extractText(File image);
}

/// Default everywhere OCR is not wired (e.g. mobile before the ML Kit impl
/// lands). Fails the item with a readable, retryable reason.
class DisabledOcrService implements OcrService {
  const DisabledOcrService();

  @override
  Future<String> extractText(File image) async {
    throw const ProcessorNotConfiguredException(
      'Image OCR is not configured on this platform.',
    );
  }
}

/// Desktop OCR via the system `tesseract` binary — the same "shell out to an
/// external tool" approach `record_linux` uses (`parecord`/`ffmpeg`). Needs
/// `tesseract` on PATH with the requested language packs; if it is missing,
/// `Process.run` throws and the item fails cleanly (retryable), so this can be
/// wired unconditionally on desktop.
class TesseractOcrService implements OcrService {
  const TesseractOcrService({
    this.languages = 'pol+eng',
    this.executable = 'tesseract',
  });

  /// `-l` value; `+`-joined tesseract language codes (`pol+eng`).
  final String languages;
  final String executable;

  @override
  Future<String> extractText(File image) async {
    if (!await image.exists()) {
      throw FileSystemException('Image file is missing.', image.path);
    }

    // `tesseract <image> stdout -l <langs>` prints recognized text to stdout.
    final ProcessResult result = await Process.run(
      executable,
      <String>[image.path, 'stdout', '-l', languages],
      stdoutEncoding: SystemEncoding(),
      stderrEncoding: SystemEncoding(),
    );

    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        <String>[image.path, 'stdout', '-l', languages],
        (result.stderr as String).trim(),
        result.exitCode,
      );
    }

    return (result.stdout as String).trim();
  }
}

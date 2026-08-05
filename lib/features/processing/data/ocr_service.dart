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

/// The default until an enrichment profile is active, on **every** platform.
///
/// OCR is LLM-only: there is no local engine to fall back to, so an image
/// captured with no vision profile configured lands `failed` with a readable
/// reason and its source intact, exactly like a transcription with no
/// transcription profile. That symmetry is the point — one endpoint to
/// configure, and the same failure shape everywhere, rather than a desktop that
/// quietly OCRs and a phone that quietly does not.
class DisabledOcrService implements OcrService {
  const DisabledOcrService();

  @override
  Future<String> extractText(File image) async {
    throw const ProcessorNotConfiguredException(
      'Image OCR needs an enrichment profile with a vision-capable model.',
    );
  }
}

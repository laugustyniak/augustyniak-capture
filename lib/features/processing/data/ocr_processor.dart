import 'dart:io';

import '../../recordings/domain/recording.dart';
import '../domain/processor.dart';
import 'ocr_service.dart';

/// Runs image items through the current [OcrService]. Resolves the service
/// lazily (a getter, like `TranscriptionProcessor`) so the shell can swap the
/// OCR backend at runtime and only subsequent work is affected. Reads the
/// source image only — never mutates or deletes it.
class OcrProcessor implements Processor {
  const OcrProcessor(this._service);

  final OcrService Function() _service;

  @override
  Future<String> process(Recording item) =>
      _service().extractText(File(item.filePath));
}

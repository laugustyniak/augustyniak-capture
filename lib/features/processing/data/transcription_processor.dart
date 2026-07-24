import 'dart:io';

import '../../recordings/domain/recording.dart';
import '../../transcription/data/transcription_service.dart';
import '../domain/processor.dart';

/// Adapts the existing [TranscriptionService] to the [Processor] interface for
/// audio items.
///
/// Holds a *resolver*, not a snapshot, because the active service is swappable
/// at runtime from the Models tab. The resolver is called once, synchronously,
/// at the start of [process] — so a swap mid-job cannot redirect work already
/// in flight, which is the same pinning rule the controller applies.
class TranscriptionProcessor implements Processor {
  const TranscriptionProcessor(this._resolveService);

  final TranscriptionService Function() _resolveService;

  @override
  Future<String> process(Recording item) {
    final TranscriptionService service = _resolveService();
    return service.transcribe(File(item.filePath));
  }
}

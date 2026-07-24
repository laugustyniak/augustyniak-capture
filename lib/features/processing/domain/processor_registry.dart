import '../../recordings/domain/capture_type.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/transcription_processor.dart';
import 'processor.dart';

/// Resolves `CaptureType → Processor`.
///
/// A plain map, constructor-injected into `RecordingsController` so tests can
/// swap in fakes. Types with no entry get an [UnavailableProcessor], which
/// fails the item cleanly rather than throwing at dispatch — the same
/// degrade-don't-crash rule as `DisabledTranscriptionService`.
class ProcessorRegistry {
  const ProcessorRegistry(this._processors);

  /// Everything Slice 0 can actually do: audio via the configured transcription
  /// service, text via passthrough. Image and video are declared unavailable
  /// until their slices land, so an item of that type fails with a readable
  /// reason instead of silently going nowhere.
  factory ProcessorRegistry.standard({
    required TranscriptionService Function() transcriptionService,
  }) {
    final TranscriptionProcessor transcription =
        TranscriptionProcessor(transcriptionService);
    return ProcessorRegistry(<CaptureType, Processor>{
      CaptureType.audioRecording: transcription,
      CaptureType.audioUpload: transcription,
      CaptureType.text: const TextPassthroughProcessor(),
      CaptureType.image: const UnavailableProcessor(
        'OCR obrazów nie jest jeszcze dostępne.',
      ),
      CaptureType.video: const UnavailableProcessor(
        'Przetwarzanie wideo nie jest jeszcze dostępne.',
      ),
    });
  }

  final Map<CaptureType, Processor> _processors;

  Processor forType(CaptureType type) =>
      _processors[type] ??
      UnavailableProcessor('Brak procesora dla typu ${type.name}.');
}

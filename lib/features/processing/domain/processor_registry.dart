import '../../recordings/domain/capture_type.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/ocr_processor.dart';
import '../data/ocr_service.dart';
import '../data/transcription_processor.dart';
import '../data/video_audio_extractor.dart';
import '../data/video_transcription_processor.dart';
import 'processor.dart';

/// Resolves `CaptureType → Processor`.
///
/// A plain map, constructor-injected into `RecordingsController` so tests can
/// swap in fakes. Types with no entry get an [UnavailableProcessor], which
/// fails the item cleanly rather than throwing at dispatch — the same
/// degrade-don't-crash rule as `DisabledTranscriptionService`.
class ProcessorRegistry {
  const ProcessorRegistry(this._processors);

  /// Audio via the configured transcription service, text via passthrough,
  /// images via the configured OCR service, and video via audio-extraction plus
  /// the transcription service. Each backend defaults to a disabled/unavailable
  /// impl so an unconfigured platform fails cleanly. All service getters resolve
  /// lazily so the Models/Config tabs can keep swapping them without rebuilding
  /// the registry.
  factory ProcessorRegistry.standard({
    required TranscriptionService Function() transcriptionService,
    OcrService Function() ocrService = _disabledOcr,
    VideoAudioExtractor Function() videoAudioExtractor = _unavailableExtractor,
  }) {
    final TranscriptionProcessor transcription =
        TranscriptionProcessor(transcriptionService);
    return ProcessorRegistry(<CaptureType, Processor>{
      CaptureType.audioRecording: transcription,
      CaptureType.audioUpload: transcription,
      CaptureType.text: const TextPassthroughProcessor(),
      CaptureType.image: OcrProcessor(ocrService),
      CaptureType.video: VideoTranscriptionProcessor(
        transcriptionService,
        videoAudioExtractor,
      ),
    });
  }

  static OcrService _disabledOcr() => const DisabledOcrService();
  static VideoAudioExtractor _unavailableExtractor() =>
      const UnavailableVideoAudioExtractor();

  final Map<CaptureType, Processor> _processors;

  Processor forType(CaptureType type) =>
      _processors[type] ??
      UnavailableProcessor('No processor for type ${type.name}.');
}

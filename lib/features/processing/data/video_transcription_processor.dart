import 'dart:io';

import '../../recordings/domain/capture_segment.dart';
import '../../transcription/data/transcription_service.dart';
import '../domain/processor.dart';
import 'video_audio_extractor.dart';

/// Video items: extract the audio track to a temp file, transcribe it with the
/// current [TranscriptionService], then delete the temp audio. The extracted
/// file is derived, so deleting it is safe — the **source video is never
/// touched**, upholding the processor rule. Both dependencies resolve lazily so
/// the shell can swap them at runtime (only later work is affected).
class VideoTranscriptionProcessor implements Processor {
  const VideoTranscriptionProcessor(
    this._transcriptionService,
    this._extractor,
  );

  final TranscriptionService Function() _transcriptionService;
  final VideoAudioExtractor Function() _extractor;

  @override
  Future<String> process(CaptureSegment segment) async {
    final File audio = await _extractor().extractAudio(
      File(segment.filePath),
    );
    try {
      return await _transcriptionService().transcribe(audio);
    } finally {
      // Best-effort cleanup of the derived temp audio (and its temp dir).
      try {
        if (await audio.exists()) {
          await audio.parent.delete(recursive: true);
        }
      } catch (_) {
        // Leaving a temp file behind must never fail the job.
      }
    }
  }
}

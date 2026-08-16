import 'dart:io';

import '../domain/local_transcription_engine.dart';
import 'transcription_service.dart';

/// Transcribes with a model on this machine.
///
/// The third implementation of `TranscriptionService`, beside the disabled one
/// and the HTTP one, and it needs no new architecture — which is the same thing
/// that made `CommandRouter` cheap behind `CaptureRouter`. Everything above the
/// seam is untouched: the drain loop reaches this minutes after the capture is
/// already verified and on disk, so the capture ordering this feature was asked
/// not to disturb is preserved by construction rather than by care.
class LocalTranscriptionService implements TranscriptionService {
  const LocalTranscriptionService({
    required LocalTranscriptionEngine engine,
    required String modelId,
    required Future<String?> Function(String modelId) modelPath,
    this.language,
  }) : _engine = engine,
       _modelId = modelId,
       _modelPath = modelPath;

  final LocalTranscriptionEngine _engine;
  final String _modelId;

  /// Resolved per call rather than captured, on the same rule the note vault
  /// reads its directory through a callback: a model can be deleted from the
  /// Models tab between two captures, and the second one must find that out
  /// rather than hand the engine a path to a file that is gone.
  final Future<String?> Function(String modelId) _modelPath;

  /// Optional ISO-639-1 hint, exactly as the remote profile carries one. It
  /// skips language detection, which on a small model is where a Polish
  /// capture most often turns into confident English.
  final String? language;

  @override
  Future<String> transcribe(File audioFile) async {
    // Checked before the model is even looked for: "this build cannot run a
    // model" and "download the one you chose" are different problems with
    // different fixes, and reporting the second when the first is true sends
    // the user off to download a file that will not help.
    if (!_engine.isAvailable) {
      throw LocalTranscriptionUnavailableException(
        _engine.unavailableReason ?? UnavailableLocalEngine.defaultReason,
      );
    }

    final String? path = await _modelPath(_modelId);
    if (path == null) throw LocalModelMissingException(_modelId);

    // Throws on failure like every other processor input check, so the
    // controller marks the item `failed` with its source intact and retryable.
    if (!await audioFile.exists()) {
      throw FileSystemException('Audio file is missing.', audioFile.path);
    }

    return _engine.transcribe(
      audio: audioFile,
      modelPath: path,
      language: language,
    );
  }
}

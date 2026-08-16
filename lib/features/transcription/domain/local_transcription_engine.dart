import 'dart:io';

/// Runs a speech model on this machine.
///
/// A second seam under `TranscriptionService`, and not ceremony: it is what
/// lets the model catalog, the store, the Models-tab section and the audio
/// decoding all be written and tested in pure Dart against a fake, while the
/// one piece that needs a native build stays behind it. The same rule that
/// keeps `AudioSplitter`, `VideoPosterExtractor` and `CommandClient` testable.
///
/// It is also what stops a platform with no native build from being a *broken*
/// app rather than an app without a feature — [isAvailable] is answered from
/// configuration, so the Models tab can say so once instead of failing once per
/// capture.
abstract interface class LocalTranscriptionEngine {
  /// Whether this build can run a model at all.
  ///
  /// Synchronous, on the same rule as `CaptureRouter.canRoute`: a section is
  /// drawn from it inside `build`, and a control that has to make a call before
  /// it knows whether it exists is a control that flickers.
  bool get isAvailable;

  /// Why not, for the one line the Models tab shows. Null when [isAvailable].
  ///
  /// Carried rather than derived at the call site, because the reasons differ
  /// per platform and only the engine knows which applies — the same thing
  /// `TokenCipher.unavailableReason` exists for.
  String? get unavailableReason;

  /// Transcribes [audio] with the model at [modelPath].
  ///
  /// Takes a path rather than loaded bytes: a model is measured in gigabytes,
  /// and handing one across this boundary as a buffer would double it in
  /// memory for no reason. The engine mmaps or streams it as its
  /// implementation prefers.
  Future<String> transcribe({
    required File audio,
    required String modelPath,
    String? language,
  });
}

/// The default everywhere until a native build exists.
///
/// Refuses rather than answering empty text, on the rule the disabled
/// transcription and OCR services already follow: an empty transcript is a
/// *result*, and a capture that produced one silently is indistinguishable
/// from one this app could not read at all.
class UnavailableLocalEngine implements LocalTranscriptionEngine {
  const UnavailableLocalEngine([this.reason = defaultReason]);

  static const String defaultReason =
      'This build has no on-device speech model support. Use a remote '
      'transcription profile, or a build that ships the native engine.';

  final String reason;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => reason;

  @override
  Future<String> transcribe({
    required File audio,
    required String modelPath,
    String? language,
  }) async => throw LocalTranscriptionUnavailableException(reason);
}

class LocalTranscriptionUnavailableException implements Exception {
  const LocalTranscriptionUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The model a local profile names is not installed, or was deleted.
///
/// Separate from [LocalTranscriptionUnavailableException] because the two call
/// for opposite next actions: one is "this build cannot do it at all", the
/// other is "download the model you already chose". Collapsing them would send
/// a user looking for a different build when a download would do.
class LocalModelMissingException implements Exception {
  const LocalModelMissingException(this.modelId);

  final String modelId;

  @override
  String toString() =>
      'The on-device model "$modelId" is not installed. Download it in the '
      'Models tab, or pick another one.';
}

import 'dart:typed_data';

/// What the screen shows while a live take is running.
///
/// [committed] is text the provider will not revise; [partial] is the current
/// guess and is replaced by every update. [failed] means the session died: the
/// recording carries on, the committed text is kept, and the take is
/// transcribed after stop like any other.
class LiveTranscript {
  const LiveTranscript({
    this.committed = '',
    this.partial = '',
    this.failed = false,
  });

  final String committed;
  final String partial;
  final bool failed;
}

/// Streaming speech-to-text used **beside** recording, never instead of
/// persisting it. The audio file is written to disk regardless; this only
/// produces text early. Anything it does wrong must fall back to the batch
/// pipeline.
abstract class LiveTranscriptionService {
  bool get isAvailable;

  /// PCM sample rate the provider expects; the recorder captures at this rate.
  int get sampleRate;

  /// Open a session. Returns at once; the connection is made in the background.
  LiveTranscriptionSession start();
}

/// The default: nothing configured, so recording behaves exactly as before.
class DisabledLiveTranscriptionService implements LiveTranscriptionService {
  const DisabledLiveTranscriptionService();

  @override
  bool get isAvailable => false;

  @override
  int get sampleRate => 16000;

  @override
  LiveTranscriptionSession start() =>
      throw StateError('Live dictation is not configured.');
}

/// [LiveTranscriptionSession.finish] could not vouch for the text it has.
class LiveTranscriptionIncomplete implements Exception {
  const LiveTranscriptionIncomplete([this.reason = 'incomplete']);

  final String reason;

  @override
  String toString() => 'LiveTranscriptionIncomplete: $reason';
}

abstract class LiveTranscriptionSession {
  Stream<LiveTranscript> get updates;

  /// Feed little-endian 16-bit mono PCM. Never throws.
  void addAudio(Uint8List pcm16le);

  /// Flush and return the full committed text. Returns only on a **clean**
  /// finish: the provider sent its final or terminal signal. Throws
  /// [LiveTranscriptionIncomplete] when the session died (drop, error, refused
  /// connection) or no such signal arrived before the session's timeout, so the
  /// caller falls back to the batch pipeline instead of trusting a text that may
  /// be missing its tail.
  Future<String> finish();

  /// Drop the session without waiting for a result.
  Future<void> cancel();
}

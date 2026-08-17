import 'dart:io';

/// Raw audio a speech model can be handed directly.
///
/// Owns its own cleanup for the same reason [AudioSegments] does: the PCM is a
/// **derived** temp artifact — many times the size of the AAC it came from —
/// and the source must outlive it, so the only safe place to decide what gets
/// deleted is the object that knows what it created.
class DecodedAudio {
  const DecodedAudio({required this.file, required Directory? tempDir})
    : _tempDir = tempDir;

  /// Headerless 16 kHz mono 32-bit float samples, little-endian.
  final File file;
  final Directory? _tempDir;

  /// Best-effort, under the rule every temp cleanup in this app follows: a
  /// directory left behind must never fail a job that already produced text.
  Future<void> dispose() async {
    final Directory? directory = _tempDir;
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // Losing a temp directory costs disk, not data.
    }
  }
}

/// Turns a capture's audio into what a local model expects.
///
/// **A seam of its own rather than a method on [AudioSplitter], which is where
/// the plan first put it.** The two cannot share a failure philosophy:
/// `UnavailableAudioSplitter.split` answers `AudioSegments.whole`, a
/// *successful* degrade that means "send it in one piece" — and there is no
/// equivalent for decoding, because no PCM is not the whole file, it is
/// nothing. One interface carrying both would force one implementation to
/// degrade and throw for the same kind of absence.
///
/// The implementations are the same two classes either way: the desktop
/// `ffmpeg` shell-out and the mobile platform channel already own the media
/// tooling, and this adds no new dependency to either.
abstract interface class AudioDecoder {
  /// Whether this build can decode at all. Synchronous, so the Models tab can
  /// say once that on-device transcription is unavailable here rather than
  /// failing once per capture — the rule `LocalTranscriptionEngine.isAvailable`
  /// already follows.
  bool get isAvailable;

  /// Decodes [audio] to 16 kHz mono 32-bit float PCM.
  ///
  /// Throws rather than degrading. A model handed silence, or handed the AAC
  /// container unchanged, does not fail — it returns confident nonsense, which
  /// is the quietest failure this path could have.
  Future<DecodedAudio> decodeToPcm(File audio);
}

/// What every platform answers until one ships a decoder.
class UnavailableAudioDecoder implements AudioDecoder {
  const UnavailableAudioDecoder([this.reason = defaultReason]);

  static const String defaultReason =
      'This build cannot decode audio for an on-device model. Use a remote '
      'transcription profile.';

  final String reason;

  @override
  bool get isAvailable => false;

  @override
  Future<DecodedAudio> decodeToPcm(File audio) async =>
      throw AudioDecodeException(audio.path, reason);
}

/// Desktop decoder via the system `ffmpeg` binary — the dependency the splitter,
/// the video extractor and the poster extractor already rely on, so a machine
/// without it fails the item cleanly and retryably rather than crashing.
class FfmpegAudioDecoder implements AudioDecoder {
  const FfmpegAudioDecoder({this.executable = 'ffmpeg'});

  final String executable;

  /// Sample rate, channel count and sample format are the model's, not a
  /// preference: whisper.cpp reads 16 kHz mono float32 and nothing else.
  static const int sampleRate = 16000;

  @override
  bool get isAvailable => true;

  @override
  Future<DecodedAudio> decodeToPcm(File audio) async {
    if (!await audio.exists()) {
      throw FileSystemException('Audio file is missing.', audio.path);
    }

    final Directory tempDir = await Directory.systemTemp.createTemp(
      'augustyniak_pcm',
    );
    final File output = File('${tempDir.path}/audio.f32le');
    final List<String> args = <String>[
      '-y',
      '-i', audio.path,
      // `-vn` because an uploaded file may carry a video stream, and ffmpeg
      // would otherwise refuse the raw output format rather than ignore it.
      '-vn',
      '-ac', '1',
      '-ar', '$sampleRate',
      '-f', 'f32le',
      '-acodec', 'pcm_f32le',
      output.path,
    ];

    // `Process.run` throws outright when the binary is missing — the documented
    // clean-failure path — so the cleanup wraps the call itself and not only a
    // non-zero exit, or every failure leaks a temp directory.
    try {
      final ProcessResult result = await Process.run(
        executable,
        args,
        stderrEncoding: SystemEncoding(),
      );
      if (result.exitCode != 0) {
        throw AudioDecodeException(
          audio.path,
          (result.stderr as String).trim().isEmpty
              ? 'ffmpeg exited ${result.exitCode}'
              : (result.stderr as String).trim(),
        );
      }
      // ffmpeg can exit 0 having written nothing — the same trap the poster
      // extractor already documents for a clip shorter than its seek. An
      // exit-code-only check would hand the model an empty buffer and get
      // confident nonsense back.
      if (!await output.exists() || await output.length() == 0) {
        throw AudioDecodeException(
          audio.path,
          'ffmpeg reported success but produced no samples',
        );
      }
      return DecodedAudio(file: output, tempDir: tempDir);
    } catch (_) {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      rethrow;
    }
  }
}

class AudioDecodeException implements Exception {
  const AudioDecodeException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'Could not decode audio for an on-device model: $reason';
}

import 'dart:io';

import 'package:path/path.dart' as p;

/// The result of asking an [AudioSplitter] for a file small enough to send.
///
/// Deliberately owns its own cleanup rather than handing back a bare list: the
/// parts are **derived** temp artifacts and the source must outlive them, so the
/// only safe place to decide what gets deleted is the object that knows which
/// files it created.
class AudioSegments {
  const AudioSegments._(this.files, this._tempDir);

  /// Nothing was split — the original travels as-is and there is nothing to
  /// clean up. Also what an unavailable splitter always answers.
  factory AudioSegments.whole(File audio) =>
      AudioSegments._(<File>[audio], null);

  /// Parts written into a temp directory this object now owns.
  factory AudioSegments.parts(List<File> files, Directory tempDir) =>
      AudioSegments._(files, tempDir);

  final List<File> files;
  final Directory? _tempDir;

  /// Whether these are derived parts rather than the source itself. Callers use
  /// it to keep the single-file path byte-identical to the pre-existing one.
  bool get isSplit => _tempDir != null;

  /// Best-effort, under the same rule the video processor's temp cleanup
  /// follows: a temp directory left behind must never fail a job that already
  /// produced its text.
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

/// Cuts an audio file into pieces short enough for one transcription request.
///
/// Same seam shape as `VideoAudioExtractor`: an interface in the feature's data
/// layer, a real implementation that shells out to the system `ffmpeg`, and an
/// unavailable default for platforms without it. The parts are derived — **the
/// source is only ever read**, upholding the processor rule one level down.
abstract interface class AudioSplitter {
  Future<AudioSegments> split(File audio, Duration maxSegment);

  /// Whether this splitter can actually divide a file. The shell reads it to
  /// decide whether recordings need a length cap: where nothing can be split,
  /// the whole file has to fit one request, and the cap is the only thing
  /// standing between the user and a silently truncated transcript.
  bool get isAvailable;
}

/// Default where the system `ffmpeg` is absent (mobile). Answers with the whole
/// file, so the decorator above it degrades to exactly the behaviour that
/// shipped before splitting existed: one file, one request.
class UnavailableAudioSplitter implements AudioSplitter {
  const UnavailableAudioSplitter();

  @override
  bool get isAvailable => false;

  @override
  Future<AudioSegments> split(File audio, Duration maxSegment) async =>
      AudioSegments.whole(audio);
}

/// Desktop splitter via the system `ffmpeg` binary — the same dependency the
/// video extractor and poster extractor already rely on, so a machine without it
/// fails the item cleanly and retryably rather than crashing.
///
/// Runs as a **stream copy**: no decode, no re-encode, no quality loss, and the
/// cut lands on an AAC frame boundary (64 ms at 16 kHz). Twenty minutes of audio
/// is under 10 MB, so the pass costs milliseconds.
class FfmpegAudioSplitter implements AudioSplitter {
  const FfmpegAudioSplitter({this.executable = 'ffmpeg'});

  final String executable;

  @override
  bool get isAvailable => true;

  @override
  Future<AudioSegments> split(File audio, Duration maxSegment) async {
    if (!await audio.exists()) {
      throw FileSystemException('Audio file is missing.', audio.path);
    }
    if (maxSegment <= Duration.zero) return AudioSegments.whole(audio);

    // Keep the source container: the parts have to stay a format the endpoint
    // accepts, and the one they came from already is.
    final String extension = p.extension(audio.path);
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'audivoa_split',
    );
    final List<String> args = <String>[
      '-y',
      '-i', audio.path,
      '-f', 'segment',
      '-segment_time', '${maxSegment.inSeconds}',
      '-c', 'copy',
      // Not an optimisation. Without it every part inherits the *source's*
      // timestamps, so a five-minute part reports itself as a twenty-minute one
      // and the model rejects it for exceeding a limit it is nowhere near. The
      // resulting 400 names a duration that appears nowhere in the request.
      '-reset_timestamps', '1',
      // Five digits so the lexicographic sort below stays the chronological one
      // well past any recording a person will make.
      p.join(tempDir.path, 'part_%05d$extension'),
    ];

    // `Process.run` throws outright when the binary is missing — the documented
    // clean-failure path — so the cleanup has to wrap the call itself, not only
    // a non-zero exit. Otherwise every failure leaks a temp directory.
    try {
      final ProcessResult result = await Process.run(
        executable,
        args,
        stderrEncoding: SystemEncoding(),
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          executable,
          args,
          (result.stderr as String).trim(),
          result.exitCode,
        );
      }

      final List<File> parts =
          (await tempDir
                  .list()
                  .where((FileSystemEntity entity) => entity is File)
                  .cast<File>()
                  .toList())
            ..sort((File a, File b) => a.path.compareTo(b.path));

      if (parts.isEmpty) {
        throw ProcessException(
          executable,
          args,
          'ffmpeg reported success but wrote no segments.',
          0,
        );
      }

      // Short input: ffmpeg still wrote a copy, but sending the original is
      // equivalent and spares the caller a temp directory it would have to
      // clean up. This is the common case — most captures are one part.
      if (parts.length == 1) {
        await tempDir.delete(recursive: true);
        return AudioSegments.whole(audio);
      }

      return AudioSegments.parts(parts, tempDir);
    } catch (_) {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      rethrow;
    }
  }
}

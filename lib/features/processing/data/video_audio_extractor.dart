import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/processor.dart';

/// Extracts a video's audio track to a standalone audio file so the existing
/// transcription pipeline can handle it. The returned file is a **derived**
/// temp artifact (not the source) — the caller deletes it after use; the source
/// video is never touched.
abstract interface class VideoAudioExtractor {
  Future<File> extractAudio(File video);
}

/// Default where no extractor is available. Fails the item cleanly and
/// retryably.
class UnavailableVideoAudioExtractor implements VideoAudioExtractor {
  const UnavailableVideoAudioExtractor([
    this.reason = 'Video audio extraction is not available on this platform.',
  ]);

  final String reason;

  @override
  Future<File> extractAudio(File video) async =>
      throw ProcessorNotConfiguredException(reason);
}

/// Desktop extractor via the system `ffmpeg` binary (already relied on by
/// `record_linux`). Produces 16 kHz mono AAC `.m4a` — the same format the app
/// records — into a fresh temp directory. A missing binary makes `Process.run`
/// throw, so the item fails cleanly and this can be wired unconditionally on
/// desktop.
class FfmpegVideoAudioExtractor implements VideoAudioExtractor {
  const FfmpegVideoAudioExtractor({this.executable = 'ffmpeg'});

  /// Prefix of the scratch directory each extraction creates.
  ///
  /// Public because the leak test finds those directories by name, and a
  /// literal repeated there is a test that silently stops testing: it counts
  /// matching directories before and after, so a prefix that matches nothing
  /// compares 0 to 0 and passes whatever the extractor does. That is exactly
  /// what happened when the product rename moved this string and the test kept
  /// the old one.
  static const String tempDirPrefix = 'augustyniak_video_audio';

  final String executable;

  @override
  Future<File> extractAudio(File video) async {
    if (!await video.exists()) {
      throw FileSystemException('Video file is missing.', video.path);
    }

    final Directory tempDir = await Directory.systemTemp.createTemp(
      tempDirPrefix,
    );
    final String outPath = p.join(tempDir.path, 'audio.m4a');
    final List<String> args = <String>[
      '-y',
      '-i', video.path,
      '-vn', // drop the video stream
      '-ac', '1',
      '-ar', '16000',
      '-c:a', 'aac',
      '-b:a', '64k',
      outPath,
    ];

    // `Process.run` itself throws when the binary is absent — the documented
    // clean-failure path on a machine without ffmpeg — so the cleanup has to
    // cover the call, not just a non-zero exit. Otherwise every failed video
    // leaves a temp directory behind.
    try {
      final ProcessResult result = await Process.run(
        executable,
        args,
        stderrEncoding: SystemEncoding(),
      );

      final File out = File(outPath);
      if (result.exitCode != 0 ||
          !await out.exists() ||
          await out.length() == 0) {
        throw ProcessException(
          executable,
          args,
          (result.stderr as String).trim(),
          result.exitCode,
        );
      }

      return out;
    } catch (_) {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      rethrow;
    }
  }
}

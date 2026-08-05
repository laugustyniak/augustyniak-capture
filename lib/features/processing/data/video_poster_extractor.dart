import 'dart:io';

import '../domain/processor.dart';

/// Extracts a single still frame from a video so the queue can show a poster
/// instead of a grey rectangle. The frame is a **derived** artifact: it is not
/// the source, it is not part of the persist-before-process guarantee, and
/// losing it costs a thumbnail and nothing else. Unlike
/// [VideoAudioExtractor] there is no temp directory — the caller owns the
/// destination path and it lives next to the source.
abstract interface class VideoPosterExtractor {
  Future<File> extractPoster(File video, File destination);
}

/// Default where no extractor is available. The caller treats a throw as "no
/// poster" and moves on.
class UnavailableVideoPosterExtractor implements VideoPosterExtractor {
  const UnavailableVideoPosterExtractor([
    this.reason = 'Video poster extraction is not available on this platform.',
  ]);

  final String reason;

  @override
  Future<File> extractPoster(File video, File destination) async =>
      throw ProcessorNotConfiguredException(reason);
}

/// Desktop extractor via the system `ffmpeg` binary — the same seam and the
/// same clean degradation as [FfmpegVideoAudioExtractor]: a missing binary
/// makes `Process.run` throw, the caller logs it, and the item is otherwise
/// unaffected. [executable] is injectable purely so a test can point it at a
/// name that does not exist.
class FfmpegVideoPosterExtractor implements VideoPosterExtractor {
  const FfmpegVideoPosterExtractor({this.executable = 'ffmpeg'});

  final String executable;

  @override
  Future<File> extractPoster(File video, File destination) async {
    if (!await video.exists()) {
      throw FileSystemException('Video file is missing.', video.path);
    }

    // A partial or zero-length destination is worse than none: it would be
    // persisted as `thumbPath` and render as a broken image forever, so every
    // failure path below deletes whatever ffmpeg left behind.
    try {
      // Seek a second in first: the opening frame of a screen recording or a
      // phone clip is very often black, and a black poster reads as a broken
      // one.
      List<String> args = _argsFor('1', video, destination);
      ProcessResult result = await Process.run(
        executable,
        args,
        stderrEncoding: SystemEncoding(),
      );

      // A clip shorter than the seek point yields no frame at all — ffmpeg
      // exits happily having written nothing. Retry once from the very start,
      // which is the only frame such a clip has.
      if (!await destination.exists() || await destination.length() == 0) {
        args = _argsFor('0', video, destination);
        result = await Process.run(
          executable,
          args,
          stderrEncoding: SystemEncoding(),
        );
      }

      if (result.exitCode != 0 ||
          !await destination.exists() ||
          await destination.length() == 0) {
        throw ProcessException(
          executable,
          args,
          (result.stderr as String).trim(),
          result.exitCode,
        );
      }

      return destination;
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  /// One frame, scaled to 320 px wide with an even height (`-2`, which the
  /// encoders require) so the poster costs kilobytes rather than megabytes.
  static List<String> _argsFor(String seek, File video, File destination) =>
      <String>[
        '-y',
        '-ss',
        seek,
        '-i',
        video.path,
        '-frames:v',
        '1',
        '-vf',
        'scale=320:-2',
        '-f',
        'image2',
        destination.path,
      ];
}

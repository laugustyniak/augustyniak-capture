import 'dart:io';

import 'package:path/path.dart' as p;

/// Repairs corrupted or unfinalized audio container files (such as .m4a files
/// missing the trailing `moov` atom due to an interrupted recording stop).
abstract interface class AudioRepairer {
  /// Attempts to repair the container of [audio] in place.
  ///
  /// Returns `true` if repair succeeded and the file is now readable by decoders,
  /// or `false` if repair was not possible or failed.
  Future<bool> repair(File audio);

  /// Whether repair tools are available in the current environment.
  bool get isAvailable;
}

/// Default no-op repairer when no repair utility is available or on platforms
/// without ffmpeg/untrunc support.
class UnavailableAudioRepairer implements AudioRepairer {
  const UnavailableAudioRepairer();

  @override
  bool get isAvailable => false;

  @override
  Future<bool> repair(File audio) async => false;
}

/// Desktop audio repairer using `untrunc` and `ffmpeg`.
///
/// When an audio capture on Linux or Desktop is salvaged after an interrupted
/// recorder process (such as a timeout on PulseAudio/PipeWire pipe drain),
/// raw AAC samples are preserved on disk in the `mdat` atom, but the trailing
/// `moov` metadata atom is missing.
///
/// This repairer uses `untrunc` with a reference .m4a header (either discovered
/// from sibling recordings in the same directory or synthesized via ffmpeg) to
/// reconstruct a valid MP4 container in place so playback and transcription proceed.
class FfmpegAudioRepairer implements AudioRepairer {
  const FfmpegAudioRepairer({
    this.ffmpegExecutable = 'ffmpeg',
    this.untruncExecutable = 'untrunc',
  });

  final String ffmpegExecutable;
  final String untruncExecutable;

  @override
  bool get isAvailable => true;

  @override
  Future<bool> repair(File audio) async {
    if (!await audio.exists()) return false;
    final int length = await audio.length();
    if (length == 0) return false;

    final String extension = p.extension(audio.path).toLowerCase();
    if (extension != '.m4a' && extension != '.mp4') return false;

    File? tempSyntheticDirFile;
    try {
      // 1. Collect candidate reference files (valid sibling recordings)
      final List<File> candidateRefs = <File>[];
      final Directory parent = audio.parent;
      if (await parent.exists()) {
        await for (final FileSystemEntity entity in parent.list()) {
          if (entity is File &&
              entity.path != audio.path &&
              (entity.path.endsWith('.m4a') || entity.path.endsWith('.mp4'))) {
            try {
              if (await entity.length() > 2048) {
                candidateRefs.add(entity);
              }
            } catch (_) {}
          }
        }
      }

      // Try candidate sibling references first
      for (final File ref in candidateRefs) {
        if (await _runUntrunc(ref, audio, extension)) {
          return true;
        }
      }

      // 2. If sibling references were absent or failed, generate a synthetic reference
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'augustyniak_ref_',
      );
      tempSyntheticDirFile = File(p.join(tempDir.path, 'reference.m4a'));
      final ProcessResult genRes = await Process.run(
        ffmpegExecutable,
        <String>[
          '-y',
          '-f', 'lavfi',
          '-i', 'sine=frequency=1000:duration=0.5:sample_rate=16000',
          '-c:a', 'aac',
          '-b:a', '64k',
          '-ac', '1',
          tempSyntheticDirFile.path,
        ],
      );
      if (genRes.exitCode == 0 && await tempSyntheticDirFile.exists()) {
        if (await _runUntrunc(tempSyntheticDirFile, audio, extension)) {
          return true;
        }
      }
    } catch (_) {
      return false;
    } finally {
      if (tempSyntheticDirFile != null) {
        try {
          final Directory parentDir = tempSyntheticDirFile.parent;
          if (await parentDir.exists()) {
            await parentDir.delete(recursive: true);
          }
        } catch (_) {}
      }
      await _cleanFixedArtifacts(audio, extension);
    }
    return false;
  }

  Future<bool> _runUntrunc(File reference, File target, String extension) async {
    try {
      final ProcessResult result = await Process.run(
        untruncExecutable,
        <String>[reference.path, target.path],
        stderrEncoding: SystemEncoding(),
      );

      if (result.exitCode != 0) return false;

      final String basePath = target.path.endsWith(extension)
          ? target.path.substring(0, target.path.length - extension.length)
          : target.path;

      final List<File> candidateOutputs = <File>[
        File('${target.path}_fixed.mp4'),
        File('${target.path}_fixed.m4a'),
        File('${basePath}_fixed.mp4'),
        File('${basePath}_fixed.m4a'),
      ];

      for (final File fixedFile in candidateOutputs) {
        if (await fixedFile.exists() && await fixedFile.length() > 0) {
          await fixedFile.copy(target.path);
          try {
            await fixedFile.delete();
          } catch (_) {}
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _cleanFixedArtifacts(File target, String extension) async {
    final String basePath = target.path.endsWith(extension)
        ? target.path.substring(0, target.path.length - extension.length)
        : target.path;
    final List<File> candidateOutputs = <File>[
      File('${target.path}_fixed.mp4'),
      File('${target.path}_fixed.m4a'),
      File('${basePath}_fixed.mp4'),
      File('${basePath}_fixed.m4a'),
    ];
    for (final File file in candidateOutputs) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}

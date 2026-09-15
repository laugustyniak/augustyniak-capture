import 'dart:io';

import 'package:path/path.dart' as p;

/// Repairs corrupted or unfinalized audio container files (such as .m4a files
/// missing the trailing `moov` atom due to an interrupted recording stop).
abstract interface class AudioRepairer {
  /// Attempts to rebuild the container of [audio] into a new file under
  /// [workDir], which the caller owns and disposes of.
  ///
  /// Returns the repaired copy, or `null` if repair was not possible or
  /// failed. **[audio] is only ever read**, and nothing is written beside it:
  /// the repairer runs one level below a processor, and `findOrphans` adopts
  /// any stray file in the recordings directory by name.
  Future<File?> repair(File audio, Directory workDir);

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
  Future<File?> repair(File audio, Directory workDir) async => null;
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
/// reconstruct a valid MP4 container. The broken file is first copied into
/// `workDir/repair/` and untrunc runs on the copy, so its `_fixed` output lands
/// there too and the source, and the directory it lives in, are never written.
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
  Future<File?> repair(File audio, Directory workDir) async {
    if (!await audio.exists()) return null;
    final int length = await audio.length();
    if (length == 0) return null;

    final String extension = p.extension(audio.path).toLowerCase();
    if (extension != '.m4a' && extension != '.mp4') return null;

    final Directory repairDir = Directory(p.join(workDir.path, 'repair'));
    File? tempSyntheticDirFile;
    try {
      await repairDir.create(recursive: true);
      final File target = await audio.copy(
        p.join(repairDir.path, 'source$extension'),
      );

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
        final File? fixed = await _runUntrunc(ref, target, extension);
        if (fixed != null) return fixed;
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
        final File? fixed =
            await _runUntrunc(tempSyntheticDirFile, target, extension);
        if (fixed != null) return fixed;
      }
    } catch (_) {
      // Fall through to the failure cleanup.
    } finally {
      if (tempSyntheticDirFile != null) {
        try {
          final Directory parentDir = tempSyntheticDirFile.parent;
          if (await parentDir.exists()) {
            await parentDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
    // Nothing usable came out: leave workDir as the caller handed it over.
    try {
      if (await repairDir.exists()) await repairDir.delete(recursive: true);
    } catch (_) {}
    return null;
  }

  /// Runs untrunc against [target] — already the copy under `repair/`, so
  /// whichever name untrunc picks for its output stays in that directory.
  Future<File?> _runUntrunc(File reference, File target, String extension) async {
    try {
      final ProcessResult result = await Process.run(
        untruncExecutable,
        <String>[reference.path, target.path],
        stderrEncoding: SystemEncoding(),
      );

      if (result.exitCode != 0) return null;

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
          return fixedFile;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../transcription/data/audio_splitter.dart';
import 'video_audio_extractor.dart';
import 'video_poster_extractor.dart';

/// Mobile media operations backed by the platform codec frameworks.
///
/// Android uses MediaExtractor/MediaMuxer/MediaMetadataRetriever; iOS uses
/// AVFoundation. No executable is spawned, so the implementation works inside
/// the mobile application sandbox and adds no bundled codec binary.
class NativeMobileMediaProcessor
    implements VideoAudioExtractor, VideoPosterExtractor, AudioSplitter {
  const NativeMobileMediaProcessor();

  static const MethodChannel _channel = MethodChannel(
    'ai.augustyniak.capture/media_processing',
  );

  static const String _videoAudioPrefix = 'augustyniak_video_audio';
  static const String _audioSplitPrefix = 'augustyniak_split';

  @override
  bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  @override
  Future<File> extractAudio(File video) async {
    await _requireSource(video, 'Video');
    final Directory tempDir = await Directory.systemTemp.createTemp(
      _videoAudioPrefix,
    );
    final File output = File(p.join(tempDir.path, 'audio.m4a'));

    try {
      await _channel.invokeMethod<void>('extractVideoAudio', <String, Object>{
        'sourcePath': video.path,
        'outputPath': output.path,
      });
      await _requireOutput(output, 'Native video audio extraction');
      return output;
    } catch (_) {
      await _deleteDirectory(tempDir);
      rethrow;
    }
  }

  @override
  Future<File> extractPoster(File video, File destination) async {
    await _requireSource(video, 'Video');
    try {
      await _channel.invokeMethod<void>('extractVideoPoster', <String, Object>{
        'sourcePath': video.path,
        'outputPath': destination.path,
      });
      await _requireOutput(destination, 'Native video poster extraction');
      return destination;
    } catch (_) {
      await _deleteFile(destination);
      rethrow;
    }
  }

  @override
  Future<AudioSegments> split(File audio, Duration maxSegment) async {
    await _requireSource(audio, 'Audio');
    if (maxSegment <= Duration.zero) return AudioSegments.whole(audio);

    final Directory tempDir = await Directory.systemTemp.createTemp(
      _audioSplitPrefix,
    );
    try {
      final List<Object?>? rawPaths = await _channel
          .invokeMethod<List<Object?>>('splitAudio', <String, Object>{
            'sourcePath': audio.path,
            'outputDirectory': tempDir.path,
            'segmentMilliseconds': maxSegment.inMilliseconds,
          });
      final List<File> parts = (rawPaths ?? const <Object?>[])
          .whereType<String>()
          .map(File.new)
          .toList(growable: false);

      if (parts.isEmpty) {
        throw const FileSystemException(
          'Native audio splitting produced no segments.',
        );
      }
      for (final File part in parts) {
        await _requireOutput(part, 'Native audio splitting');
      }

      // A short file does not need a derived copy. Keep the exact source and
      // discard the single segment emitted by the native implementation.
      if (parts.length == 1) {
        await _deleteDirectory(tempDir);
        return AudioSegments.whole(audio);
      }
      return AudioSegments.parts(parts, tempDir);
    } catch (_) {
      await _deleteDirectory(tempDir);
      rethrow;
    }
  }

  static Future<void> _requireSource(File file, String kind) async {
    if (!await file.exists()) {
      throw FileSystemException('$kind file is missing.', file.path);
    }
  }

  static Future<void> _requireOutput(File file, String operation) async {
    if (!await file.exists() || await file.length() == 0) {
      throw FileSystemException('$operation produced no output.', file.path);
    }
  }

  static Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // Cleanup must not replace the platform error that explains the failure.
    }
  }

  static Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale derived poster costs disk space, never the source capture.
    }
  }
}

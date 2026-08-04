import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_type.dart';

/// A file the user chose to import, plus its detected mime type (from the
/// extension) so storage keeps the original identity.
class PickedMedia {
  const PickedMedia({required this.file, this.mimeType});

  final File file;
  final String? mimeType;
}

/// Chooses a file to import for a given [CaptureType]. Abstracted so the
/// controller depends on this seam, not on `file_picker` directly — tests inject
/// a fake and never touch the plugin.
abstract interface class MediaPicker {
  /// Returns the picked file, or null when the user cancels.
  Future<PickedMedia?> pick(CaptureType type);
}

/// `file_picker`-backed implementation. Filters the native dialog by type and
/// derives the mime from the extension (the picker gives a temp path we copy).
class FilePickerMediaPicker implements MediaPicker {
  const FilePickerMediaPicker();

  @override
  Future<PickedMedia?> pick(CaptureType type) async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: _filterFor(type),
    );
    final List<PlatformFile>? files = result?.files;
    if (files == null || files.isEmpty) return null;
    final String? path = files.first.path;
    if (path == null) return null;
    return PickedMedia(file: File(path), mimeType: mimeForPath(path));
  }

  FileType _filterFor(CaptureType type) => switch (type) {
    CaptureType.audioUpload => FileType.audio,
    CaptureType.image => FileType.image,
    CaptureType.video => FileType.video,
    _ => FileType.any,
  };

  /// Minimal extension→mime map, matching the extensions
  /// `RecordingsRepository.extensionFor` understands, so a picked `.png` is
  /// stored as `.png` rather than the per-type fallback.
  static String? mimeForPath(String path) {
    final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'm4a' || 'aac' => 'audio/mp4',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'flac' => 'audio/flac',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      _ => null,
    };
  }
}

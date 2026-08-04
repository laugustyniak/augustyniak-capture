import 'dart:io';

import '../domain/capture_type.dart';
import '../domain/recording.dart';
import 'recordings_repository.dart';

/// Copies an externally-picked file into the app's recordings directory as an
/// item's source artifact.
///
/// This is the verify-then-persist half of `stopRecording`, extracted so it is
/// pure-Dart testable (no plugins): copy the picked file to `<id>.<ext>`,
/// verify it landed with length > 0, and return the item with status `saved`.
/// The caller indexes only after this returns, so a copy failure never produces
/// a dangling index entry — and, like every other capture path, a later
/// processing failure never deletes the source.
class MediaImporter {
  const MediaImporter(this._repository);

  final RecordingsRepository _repository;

  Future<Recording> importFile({
    required String id,
    required CaptureType type,
    required File source,
    required DateTime createdAt,
    String? mimeType,
  }) async {
    if (!await source.exists() || await source.length() == 0) {
      throw FileSystemException(
        'Picked file is missing or empty.',
        source.path,
      );
    }

    final String extension = RecordingsRepository.extensionFor(
      type,
      sourceMimeType: mimeType,
    );
    final File destination = await _repository.createSourceFile(id, extension);
    await source.copy(destination.path);

    // The same `length()` that proves the copy landed is the size the card
    // reports, so the number on screen is measured, never estimated.
    final int sizeBytes = await destination.exists()
        ? await destination.length()
        : 0;
    if (sizeBytes == 0) {
      throw FileSystemException(
        'Imported file was not persisted correctly.',
        destination.path,
      );
    }

    return Recording(
      id: id,
      filePath: destination.path,
      createdAt: createdAt,
      durationMs: 0,
      sizeBytes: sizeBytes,
      status: RecordingStatus.saved,
      type: type,
      sourceMimeType: mimeType,
    );
  }
}

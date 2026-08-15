import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/capture_archive.dart';

/// System save/open dialogs, behind [ArchiveLocationPicker].
///
/// **The two platforms disagree about who writes the file, and that is the
/// whole reason this class exists.** A desktop save dialog hands back a path
/// and expects the caller to write it; Android's storage-access framework
/// takes the bytes and writes them itself, returning only where they went.
/// `file_picker` exposes both through one call, so the split is absorbed here
/// rather than leaking into the coordinator above.
class FilePickerArchiveLocation implements ArchiveLocationPicker {
  const FilePickerArchiveLocation();

  /// Reading the staged archive into memory is the price of the SAF path, so
  /// it is only paid where that path is taken. A desktop copy streams.
  static bool get _writesItsOwnBytes => Platform.isAndroid || Platform.isIOS;

  /// What the SAF path will hold in memory before handing it to the picker.
  ///
  /// There is no streaming alternative on that path, so the only honest choice
  /// above this size is to say so. Without the check the process is OOM-killed
  /// mid-export and the user is told nothing at all — on the platform this
  /// whole feature exists for, where an archive is mostly audio and video.
  static const int maxInMemoryBytes = 512 * 1024 * 1024;

  @override
  Future<String?> deliver(File staged, String suggestedName) async {
    if (_writesItsOwnBytes) {
      final int size = await staged.length();
      if (size > maxInMemoryBytes) {
        throw ArchiveTooLargeException(size, maxInMemoryBytes);
      }
    }
    final Uint8List? bytes = _writesItsOwnBytes
        ? await staged.readAsBytes()
        : null;

    final String? chosen = await FilePicker.saveFile(
      dialogTitle: 'Save capture archive',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
      bytes: bytes,
    );
    if (chosen == null) return null;

    // On the SAF path the bytes are already written and `chosen` merely names
    // where; copying onto it again would either fail or duplicate the work.
    if (bytes == null) await staged.copy(chosen);
    return chosen;
  }

  @override
  Future<File?> chooseArchive() async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      dialogTitle: 'Choose a capture archive',
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
      // The importer streams the file off disk rather than decoding a buffer,
      // so a path is what it wants and a large archive costs no memory here.
      withData: false,
    );
    final String? path = result?.files.single.path;
    return path == null ? null : File(path);
  }
}

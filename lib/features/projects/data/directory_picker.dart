import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Chooses a directory on disk for a project's `repoPath`. Abstracted for the
/// same reason as `MediaPicker`: the editor depends on this seam, not on
/// `file_picker`, so a widget test injects a fake and never reaches the plugin.
abstract interface class DirectoryPicker {
  /// Whether a native directory dialog can be offered at all. The path field
  /// stays authoritative either way — this only decides whether the browse
  /// affordance is drawn.
  bool get isAvailable;

  /// Returns the absolute path of the chosen directory, or null when the user
  /// cancels. Throws when the dialog itself fails.
  Future<String?> pick({String? initialDirectory});
}

/// `file_picker`-backed implementation, **desktop only**.
///
/// Android answers `getDirectoryPath` from the storage-access framework, so it
/// yields a document-tree URI (`/tree/primary:Documents`) rather than a
/// filesystem path. Written into `repoPath` that would fail the way a typo
/// fails — `ProjectContextProbe` reporting `repoMissing`, an agent session
/// refusing to launch — which is exactly the indistinguishable-silence case the
/// probe exists to remove. So mobile keeps the text field and nothing else.
class FilePickerDirectoryPicker implements DirectoryPicker {
  const FilePickerDirectoryPicker();

  @override
  bool get isAvailable =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  Future<String?> pick({String? initialDirectory}) {
    return FilePicker.getDirectoryPath(
      dialogTitle: 'Choose repository directory',
      lockParentWindow: true,
      initialDirectory: initialDirectory,
    );
  }
}

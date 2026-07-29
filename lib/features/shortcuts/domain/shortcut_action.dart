/// What a global hotkey can trigger.
///
/// Every value maps onto an entry point the capture FAB already calls, so a
/// shortcut never gets its own path through the capture pipeline — it only
/// pulls the same lever from outside the window.
enum ShortcutAction {
  /// Restore, raise and focus the Audivoa window.
  showWindow,

  /// Start recording, or stop the one in progress.
  toggleRecording,

  /// Open the note compose sheet.
  newTextNote,

  /// Open the file picker for an audio upload.
  uploadAudio,

  /// Open the file picker for an image upload.
  uploadImage,

  /// Open the file picker for a video upload.
  uploadVideo;

  /// Unknown names come from a `settings.json` written by a different build.
  /// Unlike `CaptureType.fromName` there is no sensible legacy value to fall
  /// back to — an action that no longer exists is dropped, and its binding with
  /// it.
  static ShortcutAction? fromName(String? name) =>
      ShortcutAction.values.asNameMap()[name];

  String get label => switch (this) {
        ShortcutAction.showWindow => 'Pokaż okno',
        ShortcutAction.toggleRecording => 'Nagrywanie start/stop',
        ShortcutAction.newTextNote => 'Nowa notatka',
        ShortcutAction.uploadAudio => 'Wgraj plik audio',
        ShortcutAction.uploadImage => 'Wgraj obraz',
        ShortcutAction.uploadVideo => 'Wgraj wideo',
      };

  /// Whether the action opens UI (a sheet or a file dialog) and therefore needs
  /// the window raised *before* it runs.
  ///
  /// [toggleRecording] is excluded because it is the one action that must not
  /// pay for the window before capturing — not because it never shows the
  /// window. The coordinator raises it *after* a successful start, so the user
  /// sees the running timer, and leaves it alone on stop.
  bool get needsWindow => this != ShortcutAction.toggleRecording;
}

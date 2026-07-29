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
        ShortcutAction.showWindow => 'Show window',
        ShortcutAction.toggleRecording => 'Start/stop recording',
        ShortcutAction.newTextNote => 'New note',
        ShortcutAction.uploadAudio => 'Upload audio file',
        ShortcutAction.uploadImage => 'Upload image',
        ShortcutAction.uploadVideo => 'Upload video',
      };

  /// Whether the action opens UI (a sheet or a file dialog) and therefore needs
  /// the window raised first.
  ///
  /// [toggleRecording] is deliberately excluded: the entire value of a global
  /// record hotkey is that it does *not* pull the user out of whatever they are
  /// working in.
  bool get needsWindow => this != ShortcutAction.toggleRecording;
}

/// What a global hotkey can trigger.
///
/// Every value maps onto an entry point the capture FAB already calls, so a
/// shortcut never gets its own path through the capture pipeline — it only
/// pulls the same lever from outside the window.
enum ShortcutAction {
  /// Restore, raise and focus the Augustyniak Capture window.
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
  uploadVideo,

  /// Start a focus session, or pause the one running.
  ///
  /// The one action here that does not touch the capture pipeline — it pulls the
  /// same lever the Timer tab's primary button pulls, for the same reason every
  /// other value does: a shortcut must never become a second path into a
  /// feature's state machine.
  toggleTimer,

  /// Open the clipboard history sheet.
  toggleClipboardHistory;

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
    ShortcutAction.toggleTimer => 'Start/pause focus timer',
    ShortcutAction.toggleClipboardHistory => 'Show clipboard history',
  };

  /// Whether the action opens UI (a sheet or a file dialog) and therefore needs
  /// the window raised *before* it runs.
  ///
  /// [toggleRecording] and [toggleTimer] are excluded because neither may pay
  /// for the window *before* it acts — not because they never show it. A record
  /// hotkey that spends a window-manager round trip before opening the mic loses
  /// the first word, and a focus session started from inside the editor should
  /// not drag the app over the work it was started for. The coordinator raises
  /// the window *after* a successful start for both, so the user sees that it
  /// ran, and leaves it alone when they stop or pause — that half is deliberate
  /// too: the state is already recorded, and pulling the window forward would
  /// interrupt whatever they went back to.
  bool get needsWindow =>
      this != ShortcutAction.toggleRecording &&
      this != ShortcutAction.toggleTimer;
}

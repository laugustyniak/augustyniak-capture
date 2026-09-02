import 'dart:ui' show Size;

/// Swappable seam over window management, so the shortcut layer can raise the
/// app without `domain/` knowing about `window_manager`.
abstract class WindowPresenter {
  /// Restore, raise and focus the window. Must be safe to call when it is
  /// already visible and focused.
  Future<void> present();

  /// Raise the window as a compact, always-on-top palette of [size] rather than
  /// as the whole application.
  ///
  /// This exists because a clipboard hotkey that drags the entire app over the
  /// document the user is typing in defeats its own purpose, and Flutter
  /// desktop has one window: the palette *is* the main window, resized and
  /// flagged, for as long as the sheet is open.
  ///
  /// Records the bounds and flags it changed so [exitOverlay] can put them
  /// back. Calling it twice without an [exitOverlay] in between is a no-op —
  /// the second call must not overwrite the saved bounds with the overlay's own.
  Future<void> enterOverlay(Size size);

  /// Restore the bounds and flags [enterOverlay] saved. A no-op when no overlay
  /// is open, so it is safe to call from a `finally` that races a caller which
  /// already closed it.
  ///
  /// Deliberately does **not** re-raise the window: the entry is about to be
  /// pasted into the application that had focus before, and pulling ours
  /// forward again is precisely what this whole path exists to avoid.
  Future<void> exitOverlay();
}

class NoopWindowPresenter implements WindowPresenter {
  const NoopWindowPresenter();

  @override
  Future<void> present() async {}

  @override
  Future<void> enterOverlay(Size size) async {}

  @override
  Future<void> exitOverlay() async {}
}

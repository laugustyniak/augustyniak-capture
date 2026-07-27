/// Swappable seam over window management, so the shortcut layer can raise the
/// app without `domain/` knowing about `window_manager`.
abstract class WindowPresenter {
  /// Restore, raise and focus the window. Must be safe to call when it is
  /// already visible and focused.
  Future<void> present();
}

class NoopWindowPresenter implements WindowPresenter {
  const NoopWindowPresenter();

  @override
  Future<void> present() async {}
}

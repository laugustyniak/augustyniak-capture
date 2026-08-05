import 'dart:io';

import 'package:window_manager/window_manager.dart';

import '../domain/window_presenter.dart';

/// Desktop implementation via `window_manager`.
///
/// The first three calls are all needed and in this order: `show()` on its own
/// leaves a minimised window minimised, and a shown window still sits behind
/// whatever the user was typing in until `focus()` pulls it forward.
class SystemWindowPresenter implements WindowPresenter {
  const SystemWindowPresenter();

  @override
  Future<void> present() async {
    // Unconditional, not gated on `isMinimized()`: that check reads
    // `GDK_WINDOW_STATE_ICONIFIED` off the GDK window and was observed
    // returning false for a window the window manager had genuinely flagged
    // `_NET_WM_STATE_HIDDEN`, which skipped the restore and left the hotkey
    // doing nothing at all. `restore` is only deiconify + present, so calling
    // it on a window that is already up costs nothing and unmaximises nothing.
    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    await _forceToFront();
  }

  /// GNOME under X11 refuses a raise that carries no user-interaction
  /// timestamp, and `window_manager`'s `focus`/`restore` both call
  /// `gtk_window_present` without one. The observed result is not an error but
  /// a no-op with a consolation prize: the window keeps `_NET_WM_STATE_HIDDEN`
  /// and picks up `_NET_WM_STATE_DEMANDS_ATTENTION`, so the taskbar entry
  /// blinks and the window the user asked for stays exactly where it was —
  /// which is the whole feature failing, since a global hotkey is *only* useful
  /// from another application.
  ///
  /// `xdotool` sends `_NET_ACTIVE_WINDOW` with the pager source indication,
  /// which mutter honours unconditionally, and that clears `_HIDDEN`. Shelling
  /// out to a system binary is the same seam `FfmpegVideoAudioExtractor` and
  /// `FfmpegAudioSplitter` already use, with the same degradation: no
  /// `xdotool` installed means the window merely blinks in the taskbar, and
  /// everything else — the capture itself — is unaffected.
  ///
  /// Matched on pid *and* title so a second Augustyniak Capture window, or an unrelated
  /// window that happens to share the name, cannot be yanked forward instead.
  /// The title is the `MaterialApp` title in `app/app.dart`; changing it there
  /// silently costs the raise (the shortcut still captures), so keep the two in
  /// step.
  static Future<void> _forceToFront() async {
    if (!Platform.isLinux) return;
    try {
      await Process.run('xdotool', <String>[
        'search',
        '--pid',
        '$pid',
        '--name',
        r'^Augustyniak Capture$',
        'windowactivate',
        '%@',
      ]);
    } catch (_) {
      // Missing binary or a refusing window manager. Nothing to recover: the
      // window_manager calls above have already done what they can.
    }
  }
}

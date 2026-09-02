import 'package:flutter/services.dart';

/// Hands a chosen clipboard entry to whatever the user was working in when the
/// palette opened.
///
/// Two calls, and the order between them is the whole seam: [rememberTarget]
/// runs *before* the app takes focus, because no desktop platform keeps a focus
/// history that can be consulted afterwards. By the time the sheet is on screen
/// the previously active window is only recoverable if it was written down.
///
/// Same shape as `ClipboardGateway`: an interface here, a platform default that
/// degrades to leaving the entry on the clipboard, and the real implementations
/// in `data/`.
abstract interface class AutoPaste {
  /// Records the window that currently holds focus.
  ///
  /// Must be called before anything raises the app's own window. Safe to call
  /// on a platform that cannot answer — it simply remembers nothing, and
  /// [pasteToTarget] then does nothing.
  Future<void> rememberTarget();

  /// Returns focus to the remembered window and synthesises the platform's
  /// paste keystroke.
  ///
  /// A no-op when there is no remembered target, which is the honest outcome
  /// everywhere the platform refuses to say what had focus: the entry is on the
  /// clipboard and the user pastes it themselves.
  Future<void> pasteToTarget();
}

/// Every entry point exists, none of them do anything.
///
/// The default for a host with no window to give focus back to — mobile, and
/// the tests.
class DisabledAutoPaste implements AutoPaste {
  const DisabledAutoPaste();

  @override
  Future<void> rememberTarget() async {}

  @override
  Future<void> pasteToTarget() async {}
}

/// The `autoPaste` platform channel, implemented on macOS only.
///
/// [rememberTarget] is deliberately empty: the macOS side does not need one.
/// `NSApp.hide(nil)` returns focus to whatever was behind the app without
/// naming it, so there is nothing to write down — the asymmetry with
/// `XdotoolAutoPaste` is a real difference between the window servers, not an
/// omission.
///
/// Everywhere else the channel has no handler and `invokeMethod` answers
/// `MissingPluginException`; [pasteToTarget] lets that propagate to
/// `ClipboardWatcherService.pasteToActiveApp`, which is where it has always
/// been swallowed.
class ChannelAutoPaste implements AutoPaste {
  const ChannelAutoPaste();

  static const MethodChannel _channel = MethodChannel(
    'ai.augustyniak.capture/clipboard',
  );

  @override
  Future<void> rememberTarget() async {}

  @override
  Future<void> pasteToTarget() =>
      _channel.invokeMethod<void>('autoPaste').then((_) {});
}

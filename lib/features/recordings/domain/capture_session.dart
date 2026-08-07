/// Holds the operating system off a running capture.
///
/// **This is not the recorder, and that separation is the point.** `record`
/// owns the microphone; this owns the app's right to keep using it. On Android
/// microphone access has been "while-in-use" since 9, so the input is cut the
/// moment the activity stops being visible — a locked screen, a notification
/// pulled down, a switch to the browser to check the thing being dictated. The
/// capture stopped and nothing said so: no exception, no state change, the
/// timer still counting against a file that had stopped growing. On iOS the
/// process is suspended outright for want of one Info.plist key.
///
/// Same seam shape as `ClipboardSink` and `MediaOpener`: an interface here so
/// `domain/` stays free of platform channels and the pure-Dart suites can
/// assert the *ordering* without a binding, with the real implementation in
/// `data/` and a no-op default for every host that needs nothing — which is
/// every desktop, where a background process keeps its microphone.
abstract interface class CaptureSession {
  /// Called **before** the recorder opens the input, never after.
  ///
  /// Android 14 grants the microphone to a foreground service only if the
  /// service is already running and has declared the `microphone` type, so the
  /// order is a platform requirement rather than a preference.
  Future<void> begin();

  /// Called when the capture ends, however it ends — saved, discarded, capped,
  /// or failed. Releasing it is what takes the notification down; leaving one
  /// up over a recording that finished is a lie about the microphone.
  Future<void> end();
}

/// Every desktop, and every test. A background process keeps its microphone
/// there, so there is nothing to hold off.
class NoopCaptureSession implements CaptureSession {
  const NoopCaptureSession();

  @override
  Future<void> begin() async {}

  @override
  Future<void> end() async {}
}

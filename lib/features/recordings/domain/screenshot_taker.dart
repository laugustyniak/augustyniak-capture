import 'dart:io';

/// Lets the user pick a region or window of the screen and writes it as a PNG.
///
/// The same seam shape as `OcrService`: an interface here, a default that
/// degrades at use ([UnavailableScreenshotTaker]), and the real shell-out in
/// `data/`. The taker only ever *writes* [destination] — it never indexes,
/// never deletes and never decides whether a capture happened. That decision
/// belongs to `RecordingsController.captureScreenshot`, which judges the file
/// the way every other capture path judges its source: present and non-empty,
/// or nothing was captured.
abstract interface class ScreenshotTaker {
  /// Whether this platform has a tool that can write a screenshot to a file.
  bool get isAvailable;

  /// Runs the interactive selection and writes the result to [destination].
  ///
  /// A cancelled selection (Escape, a click outside) returns normally and
  /// leaves [destination] missing or empty — it is not an error. Throws
  /// [ScreenshotUnavailableException] only when there is no tool to run.
  Future<void> capture(File destination);
}

/// No screenshot tool on this platform, or none installed.
class ScreenshotUnavailableException implements Exception {
  const ScreenshotUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The default: wiring never throws, use does.
class UnavailableScreenshotTaker implements ScreenshotTaker {
  const UnavailableScreenshotTaker();

  @override
  bool get isAvailable => false;

  @override
  Future<void> capture(File destination) async {
    throw const ScreenshotUnavailableException(
      'Screenshot capture is not available on this platform.',
    );
  }
}

import 'dart:io';

import '../domain/screenshot_taker.dart';

/// How this implementation reaches the platform tool. Injected so the command
/// lines can be tested without a display server.
typedef ScreenshotProcessRun =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// The desktop's own screenshot tool, run interactively and pointed straight
/// at the capture's source path.
///
/// - macOS: `screencapture -i -x` — drag a region, or Space for a window; `-x`
///   keeps it silent.
/// - Linux: `gnome-screenshot -a -f`, falling back to `slurp` + `grim` on a
///   wlroots compositor when `gnome-screenshot` is not installed.
/// - Windows: unavailable. Snipping Tool (`ms-screenclip:`) puts the selection
///   on the clipboard rather than in a file, so there is nothing to verify;
///   the action throws [ScreenshotUnavailableException] at use, the same
///   degradation as a Linux install with neither tool.
///
/// **An exit code is not a verdict.** Every one of these tools answers a
/// cancelled selection differently (0 with no file, 1, a message on stderr),
/// so a non-zero exit is not reported as an error. The caller decides from
/// the file alone, which is how every capture path in this app decides.
class SystemScreenshotTaker implements ScreenshotTaker {
  SystemScreenshotTaker({String? operatingSystem, ScreenshotProcessRun? run})
    : _os = operatingSystem ?? Platform.operatingSystem,
      _run = run ?? Process.run;

  final String _os;
  final ScreenshotProcessRun _run;

  @override
  bool get isAvailable => _os == 'macos' || _os == 'linux';

  @override
  Future<void> capture(File destination) async {
    switch (_os) {
      case 'macos':
        await _tool('screencapture', <String>['-i', '-x', destination.path]);
      case 'linux':
        await _captureLinux(destination);
      default:
        throw ScreenshotUnavailableException(
          'Screenshot capture is not available on $_os.',
        );
    }
  }

  Future<void> _captureLinux(File destination) async {
    try {
      await _run('gnome-screenshot', <String>['-a', '-f', destination.path]);
      return;
    } on ProcessException {
      // Not installed; try the wlroots pair below.
    }

    final ProcessResult selection;
    try {
      selection = await _run('slurp', const <String>[]);
    } on ProcessException {
      throw const ScreenshotUnavailableException(
        'No screenshot tool found — install gnome-screenshot, or grim and '
        'slurp.',
      );
    }
    final String geometry = '${selection.stdout}'.trim();
    // Escape in slurp exits non-zero with no geometry: a cancelled selection.
    if (selection.exitCode != 0 || geometry.isEmpty) return;
    await _tool('grim', <String>['-g', geometry, destination.path]);
  }

  Future<void> _tool(String executable, List<String> arguments) async {
    try {
      await _run(executable, arguments);
    } on ProcessException catch (exception) {
      throw ScreenshotUnavailableException(
        '$executable is not available: ${exception.message}',
      );
    }
  }
}

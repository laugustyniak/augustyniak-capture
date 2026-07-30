import 'dart:io';

import '../domain/media_opener.dart';

/// Real opener, wired by the `RecordingsPage` shell. Hands the path to the
/// platform's default application — the same shell-out seam as
/// `SystemWindowPresenter`'s `xdotool` call and the `tesseract`/`ffmpeg`
/// processors. Kept out of `domain/` so that layer stays platform-free.
///
/// Throws on a non-zero exit code so the controller can surface it: unlike the
/// clipboard hand-off, this runs from a deliberate tap and silence would read
/// as the app being broken.
class SystemMediaOpener implements MediaOpener {
  const SystemMediaOpener();

  @override
  Future<void> open(String path) async {
    final String executable;
    final List<String> args;
    if (Platform.isLinux) {
      executable = 'xdg-open';
      args = <String>[path];
    } else if (Platform.isMacOS) {
      executable = 'open';
      args = <String>[path];
    } else if (Platform.isWindows) {
      // The empty string is `start`'s title argument: without it a quoted path
      // is taken as the window title and nothing opens.
      executable = 'cmd';
      args = <String>['/c', 'start', '', path];
    } else {
      throw UnsupportedError(
        'Opening a file externally is not supported on this platform.',
      );
    }

    final ProcessResult result = await Process.run(
      executable,
      args,
      stderrEncoding: SystemEncoding(),
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        (result.stderr as String).trim(),
        result.exitCode,
      );
    }
  }
}

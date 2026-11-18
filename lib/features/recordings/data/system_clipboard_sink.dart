import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/clipboard_sink.dart';

typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Real clipboard, wired by the `RecordingsPage` shell. Kept out of `domain/`
/// so the domain layer stays free of platform channels and stays testable
/// without a Flutter binding.
///
/// On a Linux Wayland session the text goes through `wl-copy` instead of GTK
/// (#437). Mutter accepts a selection only from the client holding keyboard
/// focus, and the copies this sink makes land when a transcription or a
/// rewrite finishes — usually while the user is in another window. GTK's
/// request is then dropped without an error, so the log said "copied" and the
/// clipboard kept its old content. `wl-copy` needs no focus. A missing binary
/// falls back to GTK, which still works while the window is focused.
class SystemClipboardSink implements ClipboardSink {
  const SystemClipboardSink({
    bool? isLinux,
    Map<String, String>? environment,
    ProcessStarter startProcess = Process.start,
    Future<void> Function(String text)? fallback,
    this.timeout = const Duration(seconds: 3),
  }) : _isLinux = isLinux,
       _environment = environment,
       _startProcess = startProcess,
       _fallback = fallback;

  final bool? _isLinux;
  final Map<String, String>? _environment;
  final ProcessStarter _startProcess;
  final Future<void> Function(String text)? _fallback;

  /// `wl-copy` forks a child that serves the selection and the parent exits,
  /// so a healthy run answers at once. The bound exists because the caller
  /// awaits this before the rewrite and enrichment run.
  final Duration timeout;

  @override
  Future<void> copy(String text) async {
    final bool wayland =
        (_isLinux ?? Platform.isLinux) &&
        ((_environment ?? Platform.environment)['WAYLAND_DISPLAY'] ?? '')
            .isNotEmpty;
    if (wayland) {
      final Process process;
      try {
        process = await _startProcess('wl-copy', <String>[
          '--type',
          'text/plain;charset=utf-8',
        ]);
      } on ProcessException {
        return _gtk(text);
      }
      process.stdin.add(utf8.encode(text));
      await process.stdin.close();
      // Only the exit code: the forked child keeps stdout/stderr open for as
      // long as it serves the selection.
      final int code = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException('wl-copy did not exit within $timeout');
        },
      );
      if (code != 0) {
        throw ProcessException('wl-copy', const <String>[], 'exit $code', code);
      }
      return;
    }
    return _gtk(text);
  }

  Future<void> _gtk(String text) => _fallback != null
      ? _fallback(text)
      : Clipboard.setData(ClipboardData(text: text));
}

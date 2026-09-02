import 'dart:io';

import '../domain/auto_paste.dart';

/// How this implementation reaches `xdotool`. Injected so the ordering — and
/// the refusals — can be tested without an X server.
typedef ProcessRun =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Linux auto-paste through `xdotool`, the counterpart of the macOS
/// `autoPaste` channel handler.
///
/// The same shell-out seam and the same degradation as `SystemWindowPresenter`
/// and the `ffmpeg` processors: no `xdotool` on `PATH`, or a Wayland session
/// where it cannot see the active window, means the entry is merely left on the
/// clipboard — which is exactly what Linux did before this class existed.
///
/// **`rememberTarget` has to run before the app raises itself.** X11 keeps no
/// focus history, so `getactivewindow` asked after the palette is up answers
/// "the palette". The window id is captured on the way in and used on the way
/// out.
class XdotoolAutoPaste implements AutoPaste {
  XdotoolAutoPaste({ProcessRun? run}) : _run = run ?? Process.run;

  final ProcessRun _run;

  /// The X window that had focus when the palette opened, or null when nothing
  /// could be recorded. Cleared by every [pasteToTarget] so a second paste
  /// cannot fire at a window the user has since closed.
  String? _target;

  /// Visible for the shell's wiring decision only.
  String? get target => _target;

  @override
  Future<void> rememberTarget() async {
    _target = null;
    final String? id = await _capture();
    // An id of 0 is what `xdotool` answers when no window is focused — a bare
    // desktop, or a Wayland session where it can see nothing. Activating it
    // would fail, so it is the same fact as having no target at all.
    if (id == null || id == '0') return;
    _target = id;
  }

  Future<String?> _capture() async {
    try {
      final ProcessResult result = await _run('xdotool', <String>[
        'getactivewindow',
      ]);
      if (result.exitCode != 0) return null;
      final String out = (result.stdout as String).trim();
      // Guard the value rather than trusting it: it is about to become an
      // argument to another process, and a non-numeric answer means `xdotool`
      // reported something other than a window id.
      return RegExp(r'^\d+$').hasMatch(out) ? out : null;
    } catch (_) {
      // Missing binary, or a session with no X display.
      return null;
    }
  }

  @override
  Future<void> pasteToTarget() async {
    final String? id = _target;
    _target = null;
    if (id == null) return;
    try {
      // `--sync` is load-bearing: without it the keystroke below races the
      // activation and lands in whichever window the WM has got to, which on a
      // slow raise is still ours.
      final ProcessResult activated = await _run('xdotool', <String>[
        'windowactivate',
        '--sync',
        id,
      ]);
      // A window that has gone away since the palette opened. Sending the
      // keystroke anyway would type Ctrl+V into whatever inherited the focus.
      if (activated.exitCode != 0) return;
      // `--clearmodifiers` releases the Ctrl+Alt still physically held from the
      // hotkey that opened the palette; without it X sees Ctrl+Alt+V and the
      // target application gets a combination nobody asked for.
      await _run('xdotool', <String>[
        'key',
        '--clearmodifiers',
        'ctrl+v',
      ]);
    } catch (_) {
      // Same degradation as everywhere else here: the entry is on the
      // clipboard and the user pastes it themselves.
    }
  }
}

import 'dart:io';

import 'executable_resolver.dart';

/// A terminal that was found on this machine, and how to ask it for a window.
///
/// Deliberately data rather than an action: the caller already owns a
/// `ProcessRunner` and already turns a `ProcessException` into an
/// `AgentSessionLaunchException`, so a terminal that spawned its own process
/// would need a second copy of that error handling.
///
/// **Finding the terminal and building its argument vector are separate steps
/// on purpose.** The command to run is only known after the session has been
/// listed and a layout written, while "is there a terminal at all" has to be
/// answered before any of that happens — otherwise a machine with none spawns
/// `zellij` and writes a layout file on its way to failing.
class ResolvedTerminal {
  const ResolvedTerminal({
    required this.executable,
    required this.argumentsFor,
  });

  /// Absolute path, never a bare name — see [ExecutableResolver] for why a
  /// bundled app cannot rely on `PATH`.
  final String executable;

  final List<String> Function(String workingDirectory, List<String> command)
  argumentsFor;
}

/// Opens a terminal window in a directory, running one command in it.
///
/// The single platform-specific step in starting an agent session. Everything
/// else the launcher does — resolving binaries, writing a Zellij layout,
/// listing sessions — is identical on every Unix, so this is the seam the
/// platform difference is confined to rather than a second launcher.
///
/// Same rules as [ExecutableResolver], and for the same reasons: resolution is
/// a property of the installation rather than of the launch, so it is cached
/// for the session; and a missing tool is reported **before** a window opens,
/// because a failure that only surfaces inside the terminal is
/// indistinguishable from the agent having nothing to say.
abstract interface class TerminalLauncher {
  /// A terminal this launcher can drive, or null when the machine has none.
  ///
  /// Called before anything is spawned, so the failure names a tool to install
  /// rather than arriving after a window has already opened and closed.
  Future<ResolvedTerminal?> resolve();

  /// What to tell the user when [resolve] answers null.
  ///
  /// Carried by the launcher rather than written at the call site because only
  /// the launcher knows what it looked for — the list differs per platform, and
  /// naming the wrong tool sends someone to install what they already have.
  String get missingTerminalMessage;

  /// The one to use on this machine.
  ///
  /// Windows deliberately gets [UnsupportedTerminalLauncher] rather than a
  /// third implementation: the session model here is Zellij's, and Zellij has
  /// no native Windows build, so a terminal alone would not make the feature
  /// work — see `docs/architecture/agent-handoff.md`.
  static TerminalLauncher forCurrentPlatform() {
    if (Platform.isMacOS) return MacOsGhosttyTerminalLauncher();
    if (Platform.isLinux) return LinuxTerminalLauncher();
    return const UnsupportedTerminalLauncher();
  }

  /// Whether an agent session can be started on this platform at all.
  ///
  /// **The single definition of that question**, read by the shell to decide
  /// whether to build a launcher — the queue hides its agent button when there
  /// is none, so a second copy of this predicate drifting from
  /// [forCurrentPlatform] would show a control that can only fail, or hide one
  /// that works. The feature spent its whole life Ghostty-and-macOS-only
  /// because the shell asked `Platform.isMacOS` directly.
  static bool get isSupportedPlatform => Platform.isMacOS || Platform.isLinux;
}

/// macOS: `/usr/bin/open -na Ghostty.app --args …`.
///
/// An app bundle is launched rather than executed, which is why this platform
/// needs no resolution step at all — `open` finds Ghostty through
/// LaunchServices, and a missing bundle surfaces as a non-zero exit from a
/// command that did run. That is also why [resolve] never answers null here:
/// there is nothing to look for ahead of time.
class MacOsGhosttyTerminalLauncher implements TerminalLauncher {
  MacOsGhosttyTerminalLauncher();

  @override
  Future<ResolvedTerminal?> resolve() async => ResolvedTerminal(
    executable: '/usr/bin/open',
    argumentsFor: (String workingDirectory, List<String> command) => <String>[
      '-na',
      'Ghostty.app',
      '--args',
      '--working-directory=$workingDirectory',
      '-e',
      ...command,
    ],
  );

  @override
  String get missingTerminalMessage =>
      'Could not open Ghostty. Install it from ghostty.org.';
}

/// Linux: the first installed terminal from [LinuxTerminal], in that order.
///
/// A terminal is executed directly here — there are no app bundles, so the
/// binary has to be found the same way `zellij` and the agent CLI are.
class LinuxTerminalLauncher implements TerminalLauncher {
  LinuxTerminalLauncher({
    ExecutableResolver? executables,
    List<LinuxTerminal>? candidates,
  }) : _executables = executables ?? PathExecutableResolver(),
       _candidates = candidates ?? LinuxTerminal.values;

  final ExecutableResolver _executables;

  /// Injectable for the same test-only reason [PathExecutableResolver]'s
  /// directory list is: left implicit, whichever terminal the developer happens
  /// to have installed decides which branch a test takes.
  final List<LinuxTerminal> _candidates;

  @override
  Future<ResolvedTerminal?> resolve() async {
    for (final LinuxTerminal terminal in _candidates) {
      final String? path = await _executables.resolve(terminal.executable);
      if (path == null) continue;
      return ResolvedTerminal(
        executable: path,
        argumentsFor: terminal.argumentsFor,
      );
    }
    return null;
  }

  @override
  String get missingTerminalMessage =>
      'Could not find a terminal to open. Install one of: '
      '${_candidates.map((LinuxTerminal t) => t.executable).join(', ')}.';
}

/// Every other platform: nothing to open, and a message that says why.
class UnsupportedTerminalLauncher implements TerminalLauncher {
  const UnsupportedTerminalLauncher();

  @override
  Future<ResolvedTerminal?> resolve() async => null;

  @override
  String get missingTerminalMessage =>
      'Agent sessions are only available on macOS and Linux.';
}

/// How each supported Linux terminal spells "run this here".
///
/// One definition per terminal on the enum, the way
/// `ProjectAgent.promptArguments` holds one per agent CLI: the shapes genuinely
/// differ — a separator (`--`), a flag (`-e`, `-x`), or a bare trailing
/// vector — and a `switch` copied to a second call site is how one of them
/// would silently start opening a shell with no command in it.
///
/// **Every form passes the command as an argument vector, never as a string.**
/// Terminals that only accept a shell string (`xterm -e "…"`, xfce4's
/// `--command`) are excluded rather than quoted for: the prompt handed to the
/// agent is the capture's own dictated text, so anything routed through a shell
/// is a quoting bug waiting for the first apostrophe.
///
/// Order is a preference, not a ranking of quality: the ones that pass a vector
/// through most predictably come first, and the desktop defaults — likelier to
/// be installed, likelier to fork to an existing server and report an exit code
/// that says nothing — come last.
enum LinuxTerminal {
  ghostty('ghostty'),
  wezterm('wezterm'),
  kitty('kitty'),
  alacritty('alacritty'),
  konsole('konsole'),
  gnomeTerminal('gnome-terminal'),
  xfce4Terminal('xfce4-terminal');

  const LinuxTerminal(this.executable);

  final String executable;

  List<String> argumentsFor(String workingDirectory, List<String> command) =>
      switch (this) {
        LinuxTerminal.ghostty => <String>[
          '--working-directory=$workingDirectory',
          '-e',
          ...command,
        ],
        LinuxTerminal.wezterm => <String>[
          'start',
          '--cwd',
          workingDirectory,
          '--',
          ...command,
        ],
        LinuxTerminal.kitty => <String>[
          '--directory',
          workingDirectory,
          ...command,
        ],
        LinuxTerminal.alacritty => <String>[
          '--working-directory',
          workingDirectory,
          '-e',
          ...command,
        ],
        LinuxTerminal.konsole => <String>[
          '--workdir',
          workingDirectory,
          '-e',
          ...command,
        ],
        LinuxTerminal.gnomeTerminal => <String>[
          '--working-directory=$workingDirectory',
          '--',
          ...command,
        ],
        // `-x` takes the rest of the vector, so it has to come last. The
        // similarly named `--command` takes one shell string and is exactly the
        // form this enum refuses.
        LinuxTerminal.xfce4Terminal => <String>[
          '--working-directory=$workingDirectory',
          '-x',
          ...command,
        ],
      };
}

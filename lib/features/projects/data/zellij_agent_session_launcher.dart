import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/security/owner_only_file.dart';
import '../../../core/security/symlink_guard.dart';
import '../domain/agent_session_launcher.dart';
import 'executable_resolver.dart';
import 'process_runner.dart';
import 'terminal_launcher.dart';

/// Desktop launcher that gives each project/agent pair one named Zellij session.
///
/// Existing sessions are only attached. New sessions start exactly one
/// controlled agent executable in a generated Zellij layout. The terminal
/// receives an argument vector; no shell command is constructed.
///
/// **Both binaries are resolved to absolute paths before anything is run**, via
/// [ExecutableResolver] — see there for why a bundled app cannot rely on `PATH`
/// at all. The rule extends inside the layout: Zellij inherits this app's
/// environment, so a bare `command="claude"` would fail in the pane for exactly
/// the same reason, and would do it after the window is already on screen.
///
/// **Only the terminal differs between platforms**, and that difference lives
/// entirely in [TerminalLauncher]. This class was macOS-only for as long as
/// `/usr/bin/open -na Ghostty.app` was written into it — everything around that
/// one call (Zellij itself, the layout file, `list-sessions`, the agent CLIs)
/// behaves identically on Linux, so the platform gate was costing the feature
/// rather than describing it.
///
/// **A detached launch never touches the terminal.** `zellij attach
/// --create-background` (0.41+) starts the server with the layout and returns
/// at once, so the agent is running before any window exists — and the
/// session is then confirmed through `list-sessions`, which is the only thing
/// that tells the truth about whether one started (#291). The terminal is
/// resolved only by [attach], when the user asks to see it.
class ZellijAgentSessionLauncher implements AgentSessionLauncher {
  ZellijAgentSessionLauncher({
    ProcessRunner processRunner = const SystemProcessRunner(),
    ExecutableResolver? executables,
    Directory? layoutDirectory,
    TerminalLauncher? terminal,
  }) : _processRunner = processRunner,
       _executables =
           executables ?? PathExecutableResolver(processRunner: processRunner),
       _layoutDirectory = layoutDirectory,
       _terminal = terminal ?? TerminalLauncher.forCurrentPlatform();

  final ProcessRunner _processRunner;
  final ExecutableResolver _executables;
  final Directory? _layoutDirectory;
  final TerminalLauncher _terminal;

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    _validateRequest(request);

    final Directory repo = Directory(request.repoPath);
    if (!repo.existsSync()) {
      throw AgentSessionLaunchException(
        'Repository directory does not exist: ${request.repoPath}',
      );
    }

    // Both asked for before anything is spawned: a missing tool has to be
    // reported as a missing tool, and a window that opens and closes again is
    // the one failure shape this launcher has already been caught producing.
    // A detached launch opens no window, so it asks for no terminal — that is
    // the point of it on a host whose terminal cannot open one.
    final ResolvedTerminal? terminal = request.detached
        ? null
        : await _terminal.resolve();
    if (terminal == null && !request.detached) {
      throw AgentSessionLaunchException(_terminal.missingTerminalMessage);
    }
    final String zellij = await _require('zellij');
    final String canonicalRepoPath = repo.absolute.path;
    final String sessionName = buildSessionName(request);
    final bool exists = await _sessionExists(zellij, sessionName);

    if (request.detached) {
      // Already running: there is nothing to start and no window to open. The
      // caller surfaces the attach the same way it does for a terminal launch
      // — the agent inside never received this prompt.
      if (!exists) {
        await _startInBackground(request, zellij, sessionName, canonicalRepoPath);
      }
      return AgentSessionLaunchResult(
        sessionName: sessionName,
        attachedToExistingSession: exists,
        detached: true,
      );
    }

    final List<String> zellijArguments;
    if (exists) {
      zellijArguments = <String>['attach', sessionName];
    } else {
      // A file rather than `--layout-string`, and that is a correctness fix
      // rather than a preference. `--layout-string` means *add a tab to the
      // session named by `--session`* — it does not create one, so Zellij
      // answered `Session '…' not found` and exited **0**, leaving Ghostty to
      // close a window that had done nothing. `--new-session-with-layout` is
      // the flag that starts a session, and it only accepts a path.
      final String layoutPath = await _writeLayout(
        sessionName,
        _buildLayout(
          request,
          canonicalRepoPath,
          await _require(request.agent.executable),
        ),
      );
      zellijArguments = <String>[
        '--session',
        sessionName,
        '--new-session-with-layout',
        layoutPath,
      ];
    }

    final CommandResult result = await _run(
      terminal!.executable,
      terminal.argumentsFor(canonicalRepoPath, <String>[
        zellij,
        ...zellijArguments,
      ]),
    );
    if (result.exitCode != 0) {
      throw AgentSessionLaunchException(
        'The terminal failed to open: ${_errorText(result)}',
      );
    }

    return AgentSessionLaunchResult(
      sessionName: sessionName,
      attachedToExistingSession: exists,
    );
  }

  @override
  Future<void> attach(String sessionName) async {
    final ResolvedTerminal? terminal = await _terminal.resolve();
    if (terminal == null) {
      throw AgentSessionLaunchException(_terminal.missingTerminalMessage);
    }
    final String zellij = await _require('zellij');
    // Checked here rather than left to Zellij: `attach` on a missing name
    // offers to create an empty session, and a window on an empty shell is
    // exactly the "agent with nothing to say" shape this launcher refuses.
    if (!await _sessionExists(zellij, sessionName)) {
      throw AgentSessionLaunchException(
        'Session `$sessionName` is not running. Hand the capture off again '
        'to start a new one.',
      );
    }
    // The session has its own working directory; the window's is irrelevant,
    // and a bundled app's current directory is `/`.
    final String home =
        Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final CommandResult result = await _run(
      terminal.executable,
      terminal.argumentsFor(home, <String>[zellij, 'attach', sessionName]),
    );
    if (result.exitCode != 0) {
      throw AgentSessionLaunchException(
        'The terminal failed to open: ${_errorText(result)}',
      );
    }
  }

  /// `zellij --new-session-with-layout FILE attach --create-background NAME`:
  /// the server starts the layout's agent pane and the client returns
  /// without attaching. Then `list-sessions` has to show the name, because a
  /// Zellij that exited 0 is not proof — the terminal path learned that the
  /// hard way (#291) and this path is not allowed to repeat it.
  Future<void> _startInBackground(
    AgentSessionLaunchRequest request,
    String zellij,
    String sessionName,
    String repoPath,
  ) async {
    final String layoutPath = await _writeLayout(
      sessionName,
      _buildLayout(request, repoPath, await _require(request.agent.executable)),
    );
    final CommandResult result = await _run(zellij, <String>[
      '--new-session-with-layout',
      layoutPath,
      'attach',
      '--create-background',
      sessionName,
    ]);
    if (result.exitCode != 0) {
      throw AgentSessionLaunchException(
        'Zellij could not start the session in the background: '
        '${_errorText(result)}',
      );
    }
    if (!await _sessionExists(zellij, sessionName)) {
      throw AgentSessionLaunchException(
        'Zellij reported success but `$sessionName` is not running. '
        "Run `zellij --new-session-with-layout '$layoutPath' attach "
        '--create-background $sessionName` in a terminal to see why.',
      );
    }
  }

  /// Absolute path of [name], or a failure that names the missing tool.
  ///
  /// Reported before the window opens, deliberately: a missing binary that only
  /// surfaces inside the terminal looks like the agent having nothing to say.
  Future<String> _require(String name) async {
    final String? resolved = await _executables.resolve(name);
    if (resolved == null) {
      throw AgentSessionLaunchException(
        'Could not find `$name` on this machine. Install it, or make sure it '
        'is in a standard location — a bundled app does not inherit the PATH '
        'from your shell.',
      );
    }
    return resolved;
  }

  /// One fresh directory per launch under the system temp directory (or the
  /// `layoutDirectory` seam), restricted to the owner before the file is
  /// written. A shared, predictably named `<tmp>/augustyniak-capture/` was a
  /// path another account could own or pre-link, and the layout is what the
  /// agent starts from (#310). Dart's `createTemp` creates at the umask's mode,
  /// so [restrictDirectoryToOwner] follows at once and the file is refused if
  /// something got in as a link meanwhile. The directory is never deleted:
  /// Zellij reads the file at start-up, and deleting it after the fact would
  /// race `open`, which returns long before Ghostty has execed anything.
  Future<String> _writeLayout(String sessionName, String layout) async {
    try {
      final Directory directory = await (_layoutDirectory ??
              Directory.systemTemp)
          .createTemp('augustyniak-capture-');
      await restrictDirectoryToOwner(directory.path);
      final File file = File(p.join(directory.path, '$sessionName.kdl'));
      await refuseSymlink(file.path);
      await file.writeAsString(layout);
      return file.path;
    } on FileSystemException catch (error) {
      throw AgentSessionLaunchException(
        'Could not write the session layout: ${error.message}',
      );
    }
  }

  Future<bool> _sessionExists(String zellij, String sessionName) async {
    final CommandResult result = await _run(zellij, const <String>[
      'list-sessions',
      '--short',
      '--no-formatting',
    ]);
    if (result.exitCode != 0) {
      // Zellij reports an empty server as a non-zero command rather than an
      // empty successful list. That is the normal first-launch state.
      final String output = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (output.contains('no active zellij sessions')) return false;
      throw AgentSessionLaunchException(
        'Could not inspect Zellij sessions: ${_errorText(result)}',
      );
    }
    return result.stdout
        .split('\n')
        .map((String line) => line.trim())
        .contains(sessionName);
  }

  Future<CommandResult> _run(String executable, List<String> arguments) async {
    try {
      return await _processRunner.run(executable, arguments);
    } on ProcessException catch (error) {
      throw AgentSessionLaunchException(
        'Could not run $executable: ${error.message}',
      );
    } on FileSystemException catch (error) {
      throw AgentSessionLaunchException(
        'Could not run $executable: ${error.message}',
      );
    }
  }

  /// `augustyniak-<project>-<id8>-<agent>`, or `<custom>-<id8>-<agent>` when the
  /// project names its own session.
  ///
  /// **The id segment is in both forms on purpose.** A session name is what
  /// [_sessionExists] matches on, so two names that collide do not produce two
  /// sessions — they produce one, and the second project silently *attaches* to
  /// the first one's, rooted in the wrong repository. Nothing stops two
  /// projects from carrying the same `sessionName`, so the id is what makes the
  /// name unique per project rather than per word the user chose.
  ///
  /// The prefix is the one thing the two forms do not share: a derived name is
  /// grouped under `augustyniak-` in `zellij ls`, while a hand-chosen one leads
  /// with the user's own words — that is the whole reason to set one.
  static String buildSessionName(AgentSessionLaunchRequest request) {
    final String? configured = request.sessionName?.trim();
    final bool custom = configured != null && configured.isNotEmpty;
    final String name = _slug(
      custom ? configured : request.projectName,
      fallback: 'project',
    );
    // Bounded rather than sliced: a uuid cut at 8 is `550e8400`, but an id like
    // `ab-cdef-gh` cuts to `ab-cdef-` and would print a double dash.
    final String stableId = _bounded(
      _slug(request.projectId, fallback: 'id'),
      8,
    );
    final String prefix = custom ? '' : 'augustyniak-';
    final String suffix =
        '-${stableId.isEmpty ? 'id' : stableId}'
        '-${request.agent.executable}';
    return '$prefix${_bounded(name, 63 - prefix.length - suffix.length)}$suffix';
  }

  /// Truncates to [max] characters without leaving a dangling separator.
  static String _bounded(String value, int max) {
    if (max <= 0) return '';
    if (value.length <= max) return value;
    return value.substring(0, max).replaceAll(RegExp(r'-+$'), '');
  }

  static void _validateRequest(AgentSessionLaunchRequest request) {
    if (request.projectId.trim().isEmpty) {
      throw const AgentSessionLaunchException('Project id cannot be empty.');
    }
    if (request.repoPath.trim().isEmpty) {
      throw const AgentSessionLaunchException(
        'Repository path cannot be empty.',
      );
    }
    for (final String argument in request.arguments) {
      if (argument.contains('\u0000')) {
        throw const AgentSessionLaunchException(
          'Agent arguments cannot contain NUL characters.',
        );
      }
    }
    if (request.prompt?.contains('\u0000') ?? false) {
      throw const AgentSessionLaunchException(
        'Agent prompt cannot contain NUL characters.',
      );
    }
  }

  static String _buildLayout(
    AgentSessionLaunchRequest request,
    String repoPath,
    String agentExecutable,
  ) {
    final StringBuffer layout = StringBuffer()
      ..writeln('layout {')
      ..writeln(
        '  pane cwd="${_escapeKdl(repoPath)}" '
        'command="${_escapeKdl(agentExecutable)}" {',
      );
    final List<String> arguments = <String>[
      ...request.arguments,
      if (request.prompt != null)
        ...request.agent.promptArguments(request.prompt!),
    ];
    if (arguments.isNotEmpty) {
      layout.write('    args');
      for (final String argument in arguments) {
        layout.write(' "${_escapeKdl(argument)}"');
      }
      layout.writeln();
    }
    layout
      ..writeln('  }')
      ..writeln('}');
    return layout.toString();
  }

  static String _escapeKdl(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');

  static String _slug(String value, {required String fallback}) {
    final String slug = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? fallback : slug;
  }

  static String _errorText(CommandResult result) {
    final String stderr = result.stderr.trim();
    return stderr.isEmpty ? 'exit code ${result.exitCode}' : stderr;
  }
}

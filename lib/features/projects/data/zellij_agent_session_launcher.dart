import 'dart:io';

import 'package:path/path.dart' as p;

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
    final ResolvedTerminal? terminal = await _terminal.resolve();
    if (terminal == null) {
      throw AgentSessionLaunchException(_terminal.missingTerminalMessage);
    }
    final String zellij = await _require('zellij');
    final String canonicalRepoPath = repo.absolute.path;
    final String sessionName = buildSessionName(request);
    final bool exists = await _sessionExists(zellij, sessionName);

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
      terminal.executable,
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

  /// One file per session name, overwritten on each launch, in the system temp
  /// directory. It is read by Zellij at start-up and is a derived artifact —
  /// deleting it after the fact would race `open`, which returns long before
  /// Ghostty has execed anything.
  Future<String> _writeLayout(String sessionName, String layout) async {
    final Directory directory =
        _layoutDirectory ??
        Directory(p.join(Directory.systemTemp.path, 'augustyniak-capture'));
    try {
      await directory.create(recursive: true);
      final File file = File(p.join(directory.path, '$sessionName.kdl'));
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
    if (request.arguments.isNotEmpty) {
      layout.write('    args');
      for (final String argument in request.arguments) {
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

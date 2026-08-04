import 'dart:io';

import '../domain/agent_session_launcher.dart';
import 'process_runner.dart';

/// macOS launcher that gives each project/agent pair one named Zellij session.
///
/// Existing sessions are only attached. New sessions start exactly one
/// controlled agent executable in a generated Zellij layout. `/usr/bin/open`
/// receives an argument vector; no shell command is constructed.
class GhosttyZellijAgentSessionLauncher implements AgentSessionLauncher {
  GhosttyZellijAgentSessionLauncher({
    ProcessRunner processRunner = const SystemProcessRunner(),
    bool? isMacOS,
  }) : _processRunner = processRunner,
       _isMacOS = isMacOS ?? Platform.isMacOS;

  final ProcessRunner _processRunner;
  final bool _isMacOS;

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    if (!_isMacOS) {
      throw const AgentSessionLaunchException(
        'Agent sessions currently require macOS, Ghostty, and Zellij.',
      );
    }
    _validateRequest(request);

    final Directory repo = Directory(request.repoPath);
    if (!repo.existsSync()) {
      throw AgentSessionLaunchException(
        'Repository directory does not exist: ${request.repoPath}',
      );
    }

    final String canonicalRepoPath = repo.absolute.path;
    final String sessionName = buildSessionName(request);
    final bool exists = await _sessionExists(sessionName);
    final List<String> zellijArguments = exists
        ? <String>['attach', sessionName]
        : <String>[
            '--session',
            sessionName,
            '--layout-string',
            _buildLayout(request, canonicalRepoPath),
          ];

    final List<String> openArguments = <String>[
      '-na',
      'Ghostty.app',
      '--args',
      '--working-directory=$canonicalRepoPath',
      '-e',
      'zellij',
      ...zellijArguments,
    ];
    final CommandResult result = await _run('/usr/bin/open', openArguments);
    if (result.exitCode != 0) {
      throw AgentSessionLaunchException(
        'Ghostty failed to open: ${_errorText(result)}',
      );
    }

    return AgentSessionLaunchResult(
      sessionName: sessionName,
      attachedToExistingSession: exists,
    );
  }

  Future<bool> _sessionExists(String sessionName) async {
    final CommandResult result = await _run('zellij', const <String>[
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

  static String buildSessionName(AgentSessionLaunchRequest request) {
    final String? configured = request.sessionName?.trim();
    final String name = _slug(
      configured == null || configured.isEmpty
          ? request.projectName
          : configured,
      fallback: 'project',
    );
    final String id = _slug(request.projectId, fallback: 'id');
    final String suffix = '-${request.agent.executable}';
    if (configured != null && configured.isNotEmpty) {
      final int availableForName = 63 - suffix.length;
      final String boundedName = name.length <= availableForName
          ? name
          : name.substring(0, availableForName);
      return '$boundedName$suffix';
    }
    final String stableId = id.length <= 8 ? id : id.substring(0, 8);
    final int availableForName =
        63 - 'augustyniak-capture--$stableId'.length - suffix.length;
    final String boundedName = name.length <= availableForName
        ? name
        : name.substring(0, availableForName);
    return 'augustyniak-capture-$boundedName-$stableId$suffix';
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
  ) {
    final StringBuffer layout = StringBuffer()
      ..writeln('layout {')
      ..writeln(
        '  pane cwd="${_escapeKdl(repoPath)}" '
        'command="${request.agent.executable}" {',
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

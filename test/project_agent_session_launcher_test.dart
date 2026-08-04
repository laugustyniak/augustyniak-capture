import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/ghostty_zellij_agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/data/process_runner.dart';
import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

class _Invocation {
  const _Invocation(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner(this.results);

  final List<CommandResult> results;
  final List<_Invocation> invocations = <_Invocation>[];

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    invocations.add(_Invocation(executable, List<String>.of(arguments)));
    return results.removeAt(0);
  }
}

const CommandResult _success = CommandResult(
  exitCode: 0,
  stdout: '',
  stderr: '',
);

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('augustyniak-capture_project_');
  });

  tearDown(() {
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  AgentSessionLaunchRequest request({
    ProjectAgent agent = ProjectAgent.codex,
    List<String> arguments = const <String>[],
  }) => AgentSessionLaunchRequest(
    projectId: '550E8400-E29B-41D4-A716-446655440000',
    projectName: 'Client / Legal Pilot',
    repoPath: repo.path,
    agent: agent,
    arguments: arguments,
  );

  test(
    'creates a sanitized named session with a structured agent command',
    () async {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
        _success,
        _success,
      ]);
      final GhosttyZellijAgentSessionLauncher launcher =
          GhosttyZellijAgentSessionLauncher(
            processRunner: runner,
            isMacOS: true,
          );

      final AgentSessionLaunchResult result = await launcher.launch(
        request(arguments: <String>['--model', 'x; touch /tmp/not-run']),
      );

      expect(
        result.sessionName,
        'augustyniak-capture-client-legal-pilot-550e8400-codex',
      );
      expect(result.attachedToExistingSession, isFalse);
      expect(runner.invocations.first.executable, 'zellij');
      expect(runner.invocations.first.arguments, const <String>[
        'list-sessions',
        '--short',
        '--no-formatting',
      ]);
      final _Invocation open = runner.invocations.last;
      expect(open.executable, '/usr/bin/open');
      expect(open.arguments.take(6), <String>[
        '-na',
        'Ghostty.app',
        '--args',
        '--working-directory=${repo.absolute.path}',
        '-e',
        'zellij',
      ]);
      expect(open.arguments, contains('--layout-string'));
      final String layout =
          open.arguments[open.arguments.indexOf('--layout-string') + 1];
      expect(layout, contains('command="codex"'));
      expect(layout, contains('"x; touch /tmp/not-run"'));
      expect(open.arguments, isNot(contains('sh')));
      expect(open.arguments, isNot(contains('-c')));
    },
  );

  test('treats Zellij no-sessions exit as a valid first launch', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
      const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'No active zellij sessions found.',
      ),
      _success,
    ]);
    final GhosttyZellijAgentSessionLauncher launcher =
        GhosttyZellijAgentSessionLauncher(processRunner: runner, isMacOS: true);

    final AgentSessionLaunchResult result = await launcher.launch(request());

    expect(result.attachedToExistingSession, isFalse);
    expect(runner.invocations.last.arguments, contains('--layout-string'));
  });

  test('sanitizes a project-configured session base and appends agent', () {
    final AgentSessionLaunchRequest configured = AgentSessionLaunchRequest(
      projectId: 'ignored-for-custom-name',
      projectName: 'Ignored',
      repoPath: repo.path,
      agent: ProjectAgent.gemini,
      sessionName: '  My Client / Workspace  ',
    );

    expect(
      GhosttyZellijAgentSessionLauncher.buildSessionName(configured),
      'my-client-workspace-gemini',
    );
  });

  test(
    'attaches without starting a second agent when session exists',
    () async {
      const String session =
          'augustyniak-capture-client-legal-pilot-550e8400-claude';
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
        const CommandResult(exitCode: 0, stdout: '$session\n', stderr: ''),
        _success,
      ]);
      final GhosttyZellijAgentSessionLauncher launcher =
          GhosttyZellijAgentSessionLauncher(
            processRunner: runner,
            isMacOS: true,
          );

      final AgentSessionLaunchResult result = await launcher.launch(
        request(agent: ProjectAgent.claude),
      );

      expect(result.attachedToExistingSession, isTrue);
      expect(
        runner.invocations.last.arguments,
        containsAllInOrder(<String>['-e', 'zellij', 'attach', session]),
      );
      expect(
        runner.invocations.last.arguments,
        isNot(contains('--layout-string')),
      );
    },
  );

  test('maps each supported agent to its controlled executable', () async {
    for (final ProjectAgent agent in ProjectAgent.values) {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
        _success,
        _success,
      ]);
      final GhosttyZellijAgentSessionLauncher launcher =
          GhosttyZellijAgentSessionLauncher(
            processRunner: runner,
            isMacOS: true,
          );

      await launcher.launch(request(agent: agent));

      final List<String> openArgs = runner.invocations.last.arguments;
      final String layout = openArgs[openArgs.indexOf('--layout-string') + 1];
      expect(layout, contains('command="${agent.executable}"'));
    }
  });

  test(
    'fails clearly on unsupported platforms without running a process',
    () async {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
      final GhosttyZellijAgentSessionLauncher launcher =
          GhosttyZellijAgentSessionLauncher(
            processRunner: runner,
            isMacOS: false,
          );

      await expectLater(
        launcher.launch(request()),
        throwsA(
          isA<AgentSessionLaunchException>().having(
            (AgentSessionLaunchException error) => error.message,
            'message',
            contains('require macOS'),
          ),
        ),
      );
      expect(runner.invocations, isEmpty);
    },
  );

  test('rejects a missing repository before running a process', () async {
    repo.deleteSync(recursive: true);
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
    final GhosttyZellijAgentSessionLauncher launcher =
        GhosttyZellijAgentSessionLauncher(processRunner: runner, isMacOS: true);

    await expectLater(
      launcher.launch(request()),
      throwsA(isA<AgentSessionLaunchException>()),
    );
    expect(runner.invocations, isEmpty);
  });
}

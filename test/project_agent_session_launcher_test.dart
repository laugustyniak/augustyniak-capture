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
    repo = Directory.systemTemp.createTempSync('augustyniak_capture_project_');
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

      expect(result.sessionName, 'augustyniak-client-legal-pilot-550e8400-codex');
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
      projectId: '550E8400-E29B-41D4-A716-446655440000',
      projectName: 'Ignored once a session name is set',
      repoPath: repo.path,
      agent: ProjectAgent.gemini,
      sessionName: '  My Client / Workspace  ',
    );

    // The user's words lead — that is the point of naming a session — but the
    // project id still rides along, for the reason the next test states.
    expect(
      GhosttyZellijAgentSessionLauncher.buildSessionName(configured),
      'my-client-workspace-550e8400-gemini',
    );
  });

  test('two projects sharing a session name do not share a session', () {
    AgentSessionLaunchRequest named(String projectId) =>
        AgentSessionLaunchRequest(
          projectId: projectId,
          projectName: 'Shared name',
          repoPath: repo.path,
          agent: ProjectAgent.claude,
          sessionName: 'client-work',
        );

    // Without the id segment both would resolve to `client-work-claude`,
    // `_sessionExists` would report a hit for the second project, and it would
    // attach to a session whose panes are open in the *first* project's repo.
    expect(
      GhosttyZellijAgentSessionLauncher.buildSessionName(
        named('550E8400-E29B-41D4-A716-446655440000'),
      ),
      isNot(
        GhosttyZellijAgentSessionLauncher.buildSessionName(
          named('6BA7B810-9DAD-11D1-80B4-00C04FD430C8'),
        ),
      ),
    );
  });

  test('a truncated id never leaves a dangling separator', () {
    final AgentSessionLaunchRequest shortId = AgentSessionLaunchRequest(
      projectId: 'ab-cdef-gh-ij',
      projectName: 'Notes',
      repoPath: repo.path,
      agent: ProjectAgent.codex,
    );

    // `ab-cdef-gh-ij` cut at 8 is `ab-cdef-`; the separator has to go, or the
    // name reads `augustyniak-notes-ab-cdef--codex`.
    expect(
      GhosttyZellijAgentSessionLauncher.buildSessionName(shortId),
      'augustyniak-notes-ab-cdef-codex',
    );
  });

  test(
    'attaches without starting a second agent when session exists',
    () async {
      const String session = 'augustyniak-client-legal-pilot-550e8400-claude';
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

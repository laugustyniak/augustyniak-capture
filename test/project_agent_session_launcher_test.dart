import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/executable_resolver.dart';
import 'package:augustyniak_capture/features/projects/data/zellij_agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/data/process_runner.dart';
import 'package:augustyniak_capture/features/projects/data/terminal_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the machine's installed tools. Every name resolves under
/// `/opt/fake/bin` unless [missing] names it — which is how the "not installed"
/// path is exercised without depending on what this machine happens to have.
class _FakeResolver implements ExecutableResolver {
  const _FakeResolver({this.missing = const <String>{}});

  final Set<String> missing;

  @override
  Future<String?> resolve(String name) async =>
      missing.contains(name) ? null : '/opt/fake/bin/$name';
}

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
  late Directory layouts;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('augustyniak_capture_project_');
    layouts = Directory.systemTemp.createTempSync(
      'augustyniak_capture_layouts_',
    );
  });

  tearDown(() {
    if (repo.existsSync()) repo.deleteSync(recursive: true);
    if (layouts.existsSync()) layouts.deleteSync(recursive: true);
  });

  /// Defaults to the macOS terminal so every assertion below keeps describing
  /// the `open -na Ghostty.app` vector this launcher has always produced —
  /// enabling Linux must not quietly change what macOS does.
  ZellijAgentSessionLauncher build(
    ProcessRunner runner, {
    TerminalLauncher? terminal,
    Set<String> missing = const <String>{},
  }) => ZellijAgentSessionLauncher(
    processRunner: runner,
    executables: _FakeResolver(missing: missing),
    layoutDirectory: layouts,
    terminal: terminal ?? MacOsGhosttyTerminalLauncher(),
  );

  /// The layout Zellij will actually read, fetched the way Zellij fetches it —
  /// off the path in the argument vector, not off anything the launcher kept.
  String layoutFrom(List<String> openArguments) {
    final int index = openArguments.indexOf('--new-session-with-layout');
    expect(index, isNot(-1), reason: 'no layout was passed to Zellij');
    return File(openArguments[index + 1]).readAsStringSync();
  }

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
      final ZellijAgentSessionLauncher launcher = build(runner);

      final AgentSessionLaunchResult result = await launcher.launch(
        request(arguments: <String>['--model', 'x; touch /tmp/not-run']),
      );

      expect(
        result.sessionName,
        'augustyniak-client-legal-pilot-550e8400-codex',
      );
      expect(result.attachedToExistingSession, isFalse);
      // Absolute, never the bare name: a bundled app's PATH is
      // `/usr/bin:/bin:/usr/sbin:/sbin`, so `zellij` alone throws here and
      // `command="codex"` would fail inside a window that is already open.
      expect(runner.invocations.first.executable, '/opt/fake/bin/zellij');
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
        '/opt/fake/bin/zellij',
      ]);
      // `--layout-string` adds a tab to a session that already exists; it does
      // not create one. It answered `Session '…' not found` and exited 0, so
      // Ghostty closed a window that had started nothing.
      expect(open.arguments, isNot(contains('--layout-string')));
      expect(
        open.arguments,
        containsAllInOrder(<String>[
          '--session',
          'augustyniak-client-legal-pilot-550e8400-codex',
          '--new-session-with-layout',
        ]),
      );
      final String layout = layoutFrom(open.arguments);
      expect(layout, contains('command="/opt/fake/bin/codex"'));
      expect(layout, contains('"x; touch /tmp/not-run"'));
      expect(open.arguments, isNot(contains('sh')));
      expect(open.arguments, isNot(contains('-c')));
    },
  );

  test('a tool that is not installed is named before a window opens', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
    final ZellijAgentSessionLauncher launcher = build(
      runner,
      missing: <String>{'zellij'},
    );

    await expectLater(
      launcher.launch(request()),
      throwsA(
        isA<AgentSessionLaunchException>().having(
          (AgentSessionLaunchException error) => error.message,
          'message',
          allOf(contains('zellij'), contains('PATH')),
        ),
      ),
    );
    // Nothing ran, so there is no terminal on screen to explain away. A missing
    // binary that only surfaces inside the window reads as a silent agent.
    expect(runner.invocations, isEmpty);
  });

  test('a missing agent is caught before the session is created', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
      _success,
    ]);
    final ZellijAgentSessionLauncher launcher = build(
      runner,
      missing: <String>{'codex'},
    );

    await expectLater(
      launcher.launch(request()),
      throwsA(
        isA<AgentSessionLaunchException>().having(
          (AgentSessionLaunchException error) => error.message,
          'message',
          contains('codex'),
        ),
      ),
    );
    // The session listing ran; `open` did not.
    expect(runner.invocations, hasLength(1));
  });

  test('a multi-line prompt survives into the layout', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
      _success,
      _success,
    ]);
    final ZellijAgentSessionLauncher launcher = build(runner);

    await launcher.launch(
      request(
        agent: ProjectAgent.claude,
        arguments: <String>['Fix the "save" button.\nIt drops the last edit.'],
      ),
    );

    // KDL escapes it going in; Zellij unescapes it going out. Writing the
    // layout to a file is also what keeps a long capture off the command line
    // and therefore out of ARG_MAX.
    final String layout = layoutFrom(runner.invocations.last.arguments);
    expect(
      layout,
      contains(r'"Fix the \"save\" button.\nIt drops the last edit."'),
    );
  });

  test('treats Zellij no-sessions exit as a valid first launch', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
      const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'No active zellij sessions found.',
      ),
      _success,
    ]);
    final ZellijAgentSessionLauncher launcher = build(runner);

    final AgentSessionLaunchResult result = await launcher.launch(request());

    expect(result.attachedToExistingSession, isFalse);
    expect(
      runner.invocations.last.arguments,
      contains('--new-session-with-layout'),
    );
  });

  test('sanitizes a project-configured session base and appends agent', () {
    final AgentSessionLaunchRequest configured = AgentSessionLaunchRequest(
      projectId: '550E8400-E29B-41D4-A716-446655440000',
      projectName: 'Ignored once a session name is set',
      repoPath: repo.path,
      agent: ProjectAgent.antigravity,
      sessionName: '  My Client / Workspace  ',
    );

    // The user's words lead — that is the point of naming a session — but the
    // project id still rides along, for the reason the next test states.
    expect(
      ZellijAgentSessionLauncher.buildSessionName(configured),
      'my-client-workspace-550e8400-agy',
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
      ZellijAgentSessionLauncher.buildSessionName(
        named('550E8400-E29B-41D4-A716-446655440000'),
      ),
      isNot(
        ZellijAgentSessionLauncher.buildSessionName(
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
      ZellijAgentSessionLauncher.buildSessionName(shortId),
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
      final ZellijAgentSessionLauncher launcher = build(runner);

      final AgentSessionLaunchResult result = await launcher.launch(
        request(agent: ProjectAgent.claude),
      );

      expect(result.attachedToExistingSession, isTrue);
      expect(
        runner.invocations.last.arguments,
        containsAllInOrder(<String>[
          '-e',
          '/opt/fake/bin/zellij',
          'attach',
          session,
        ]),
      );
      expect(
        runner.invocations.last.arguments,
        isNot(contains('--new-session-with-layout')),
      );
    },
  );

  test('maps each supported agent to its controlled executable', () async {
    for (final ProjectAgent agent in ProjectAgent.values) {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
        _success,
        _success,
      ]);
      final ZellijAgentSessionLauncher launcher = build(runner);

      await launcher.launch(request(agent: agent));

      final String layout = layoutFrom(runner.invocations.last.arguments);
      expect(layout, contains('command="/opt/fake/bin/${agent.executable}"'));
    }
  });

  test(
    'fails clearly on unsupported platforms without running a process',
    () async {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
      final ZellijAgentSessionLauncher launcher = build(
        runner,
        terminal: const UnsupportedTerminalLauncher(),
      );

      await expectLater(
        launcher.launch(request()),
        throwsA(
          isA<AgentSessionLaunchException>().having(
            (AgentSessionLaunchException error) => error.message,
            'message',
            contains('only available on macOS and Linux'),
          ),
        ),
      );
      // Nothing spawned, and no layout written: the terminal is looked for
      // before `zellij list-sessions`, so a machine that cannot open a window
      // never starts a server on its way to saying so.
      expect(runner.invocations, isEmpty);
      expect(layouts.listSync(), isEmpty);
    },
  );

  test('runs the whole session through a resolved Linux terminal', () async {
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[
      _success,
      _success,
    ]);
    final ZellijAgentSessionLauncher launcher = build(
      runner,
      terminal: LinuxTerminalLauncher(
        executables: const _FakeResolver(),
        // Pinned rather than left to `LinuxTerminal.values`, so the assertion
        // below describes one terminal's vector instead of whichever one the
        // machine running the suite happens to have first.
        candidates: const <LinuxTerminal>[LinuxTerminal.kitty],
      ),
    );

    final AgentSessionLaunchResult result = await launcher.launch(request());

    expect(result.attachedToExistingSession, isFalse);
    final _Invocation open = runner.invocations.last;
    expect(open.executable, '/opt/fake/bin/kitty');
    expect(open.arguments.take(3), <String>[
      '--directory',
      repo.path,
      '/opt/fake/bin/zellij',
    ]);
    // The layout still reaches Zellij by path, exactly as it does on macOS.
    expect(
      layoutFrom(open.arguments),
      contains('command="/opt/fake/bin/codex"'),
    );
  });

  test(
    'reports what to install when no terminal is present, before spawning',
    () async {
      final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
      final ZellijAgentSessionLauncher launcher = build(
        runner,
        terminal: LinuxTerminalLauncher(
          executables: const _FakeResolver(
            missing: <String>{'ghostty', 'wezterm', 'kitty'},
          ),
          candidates: const <LinuxTerminal>[
            LinuxTerminal.ghostty,
            LinuxTerminal.wezterm,
            LinuxTerminal.kitty,
          ],
        ),
      );

      await expectLater(
        launcher.launch(request()),
        throwsA(
          isA<AgentSessionLaunchException>().having(
            (AgentSessionLaunchException error) => error.message,
            'message',
            allOf(contains('ghostty'), contains('wezterm'), contains('kitty')),
          ),
        ),
      );
      expect(runner.invocations, isEmpty);
    },
  );

  test('rejects a missing repository before running a process', () async {
    repo.deleteSync(recursive: true);
    final _FakeProcessRunner runner = _FakeProcessRunner(<CommandResult>[]);
    final ZellijAgentSessionLauncher launcher = build(runner);

    await expectLater(
      launcher.launch(request()),
      throwsA(isA<AgentSessionLaunchException>()),
    );
    expect(runner.invocations, isEmpty);
  });
}

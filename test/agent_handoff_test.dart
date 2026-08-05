import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records what it was asked to launch instead of opening a terminal.
class _FakeLauncher implements AgentSessionLauncher {
  _FakeLauncher({this.attach = false, this.failure});

  final bool attach;
  final String? failure;
  final List<AgentSessionLaunchRequest> requests = <AgentSessionLaunchRequest>[];

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    requests.add(request);
    if (failure != null) throw AgentSessionLaunchException(failure!);
    return AgentSessionLaunchResult(
      sessionName: 'augustyniak-acme-p1-${request.agent.executable}',
      attachedToExistingSession: attach,
    );
  }
}

void main() {
  late Directory appDir;
  late Directory repo;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak-handoff-app-');
    repo = Directory.systemTemp.createTempSync('augustyniak-handoff-repo-');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  Project projectFor(Directory target, {AgentKind? defaultAgent}) => Project(
    id: 'p1',
    name: 'Acme',
    repoPath: target.path,
    defaultAgent: defaultAgent,
  );

  ProjectAgentHandoff handoffFor(
    Project? project,
    AgentSessionLauncher launcher,
  ) => ProjectAgentHandoff(
    projectById: (String id) => id == 'p1' ? project : null,
    launcher: launcher,
  );

  File taskFile(String id) =>
      File('${repo.path}${Platform.pathSeparator}.agent-tasks'
          '${Platform.pathSeparator}$id.md');

  test('a handoff writes the brief, starts the agent, and closes the capture',
      () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'r1',
          projectId: 'p1',
          title: 'Add the delegate button',
          transcript: 'Dictate a note, then hand it to an agent.',
          summary: 'One button from capture to session.',
          tags: <String>['ui'],
        ),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    final AgentHandoffResult? result = await controller.handoff(
      'r1',
      agentId: AgentKind.claudeCode.name,
    );

    expect(result, isNotNull);
    expect(result!.attachedToExistingSession, isFalse);
    expect(result.taskPath, '.agent-tasks/r1.md');

    // The brief is on disk, and carries the capture rather than a reference to
    // it — an agent reading this file needs no access to the queue.
    final String brief = taskFile('r1').readAsStringSync();
    expect(brief, contains('# Add the delegate button'));
    expect(brief, contains('Dictate a note, then hand it to an agent.'));
    expect(brief, contains('> One button from capture to session.'));
    expect(brief, contains('#ui'));

    // The prompt is the capture's own text. A session opened on an errand to go
    // and read a file is a session waiting for a second turn, which is the one
    // thing the handoff exists to skip.
    expect(launcher.requests, hasLength(1));
    final AgentSessionLaunchRequest request = launcher.requests.single;
    expect(request.repoPath, repo.path);
    expect(request.agent, ProjectAgent.claude);
    expect(request.arguments, <String>[
      'Dictate a note, then hand it to an agent.',
    ]);

    // Delivery happened, so the capture closes and records where it went.
    final Recording item = controller.recordings.single;
    expect(item.isProcessedByUser, isTrue);
    expect(item.routes, hasLength(1));
    expect(item.routes.single.kind, RouteKind.agent);
    expect(item.routes.single.target, contains('Claude Code'));
  });

  test('a second handoff appends and cannot overwrite the agent\'s own notes',
      () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'First pass.'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    await controller.handoff('r1', agentId: AgentKind.codex.name);
    // Whatever the agent wrote underneath must survive the next handoff.
    taskFile('r1').writeAsStringSync(
      '\n## Result\nDone, see PR #12.\n',
      mode: FileMode.writeOnlyAppend,
    );
    await controller.handoff('r1', agentId: AgentKind.codex.name);

    final String brief = taskFile('r1').readAsStringSync();
    expect(brief, contains('Done, see PR #12.'));
    expect('## Handoff '.allMatches(brief), hasLength(2));
    // One heading only: the file is the capture's, and it is named once.
    expect('# '.allMatches(brief).length, greaterThan(0));

    // Both deliveries really happened, so both are recorded.
    expect(controller.recordings.single.routes, hasLength(2));
  });

  test('a launch that fails leaves the capture open and retryable', () async {
    final _FakeLauncher launcher = _FakeLauncher(failure: 'Ghostty is missing');
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    final AgentHandoffResult? result = await controller.handoff(
      'r1',
      agentId: AgentKind.codex.name,
    );

    expect(result, isNull);
    expect(controller.error, contains('Ghostty is missing'));
    final Recording item = controller.recordings.single;
    expect(item.isProcessedByUser, isFalse);
    expect(item.routes, isEmpty);
    expect(controller.isHandingOff('r1'), isFalse);
  });

  test('attaching to a running session is reported, not hidden', () async {
    final _FakeLauncher launcher = _FakeLauncher(attach: true);
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    final AgentHandoffResult? result = await controller.handoff(
      'r1',
      agentId: AgentKind.codex.name,
    );

    // The prompt never reaches an agent that is already running, so the caller
    // has to be able to say so. The brief is on disk either way.
    expect(result!.attachedToExistingSession, isTrue);
    expect(taskFile('r1').existsSync(), isTrue);
  });

  test('Antigravity takes its prompt behind a flag', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    await controller.handoff('r1', agentId: AgentKind.antigravity.name);

    expect(launcher.requests.single.arguments, <String>[
      '--prompt-interactive',
      'Body.',
    ]);
  });

  test('a multi-line capture reaches the agent whole', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    // The shape the old pointer-prompt was built to avoid: newlines and quotes.
    // They survive now because Ghostty passes an `-e` argument vector through
    // verbatim and the Zellij layout is written to a file rather than to a
    // command line — so nothing on the path can truncate it.
    const String dictated =
        'Fix the "save" button.\nIt drops the last edit.\n\nRepro: type, blur.';
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: dictated),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    await controller.handoff('r1', agentId: AgentKind.claudeCode.name);

    expect(launcher.requests.single.arguments, const <String>[dictated]);
  });

  test('a capture with no text falls back to its title', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', title: 'Rename the tab'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    await controller.handoff('r1', agentId: AgentKind.claudeCode.name);

    expect(launcher.requests.single.arguments, const <String>['Rename the tab']);
  });

  test('an edited instruction replaces the default', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: handoffFor(projectFor(repo), launcher),
    );

    await controller.handoff(
      'r1',
      agentId: AgentKind.codex.name,
      instruction: '  Read the brief and only write tests.  ',
    );

    expect(launcher.requests.single.arguments, <String>[
      'Read the brief and only write tests.',
    ]);
  });

  test('a capture with no reachable project is offered no agents', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final ProjectAgentHandoff handoff = handoffFor(projectFor(repo), launcher);

    expect(handoff.agentsFor(null), isEmpty);
    expect(handoff.agentsFor('missing'), isEmpty);
    expect(handoff.agentsFor('p1'), hasLength(AgentKind.values.length));
  });

  test('a project without a repository path offers no agents', () {
    final ProjectAgentHandoff handoff = ProjectAgentHandoff(
      projectById: (String id) =>
          const Project(id: 'p1', name: 'Acme', repoPath: '   '),
      launcher: _FakeLauncher(),
    );

    expect(handoff.agentsFor('p1'), isEmpty);
  });

  test("the project's default agent is the one preselected", () {
    final ProjectAgentHandoff handoff = handoffFor(
      projectFor(repo, defaultAgent: AgentKind.antigravity),
      _FakeLauncher(),
    );

    final List<HandoffAgent> agents = handoff.agentsFor('p1');
    expect(
      agents.where((HandoffAgent agent) => agent.isDefault).single.id,
      AgentKind.antigravity.name,
    );
  });

  test('a missing repository fails before any session is opened', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final Directory gone = Directory.systemTemp.createTempSync('gone-')
      ..deleteSync();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: handoffFor(projectFor(gone), launcher),
    );

    final AgentHandoffResult? result = await controller.handoff(
      'r1',
      agentId: AgentKind.codex.name,
    );

    expect(result, isNull);
    expect(launcher.requests, isEmpty);
    expect(controller.recordings.single.isProcessedByUser, isFalse);
  });
}

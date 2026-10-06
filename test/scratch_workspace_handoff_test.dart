import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLauncher implements AgentSessionLauncher {
  final List<AgentSessionLaunchRequest> requests =
      <AgentSessionLaunchRequest>[];

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    requests.add(request);
    return AgentSessionLaunchResult(
      sessionName: request.sessionName ?? 'x',
      attachedToExistingSession: false,
    );
  }
}

AgentHandoffRequest _request(String id, {String? projectId}) =>
    AgentHandoffRequest(
      capture: RoutedCapture(
        id: id,
        projectId: projectId,
        title: 'Split the router',
        body: 'Split the tokenizer out of the parser.',
        type: CaptureType.audioRecording,
        capturedAt: DateTime.utc(2026, 10, 7, 9),
      ),
      agentId: 'claudeCode',
      instruction: 'Split the router.',
    );

void main() {
  late Directory root;
  late _FakeLauncher launcher;

  setUp(() {
    root = Directory.systemTemp.createTempSync('augustyniak-scratch-');
    launcher = _FakeLauncher();
  });

  tearDown(() => root.deleteSync(recursive: true));

  ProjectAgentHandoff handoffWith(
    Map<String, Project> projects, {
    Directory? Function()? sessionsRoot,
  }) => ProjectAgentHandoff(
    projectById: (String id) => projects[id],
    launcher: launcher,
    sessionsRoot: sessionsRoot,
  );

  File brief(String id) => File(
    '${root.path}${Platform.pathSeparator}$id${Platform.pathSeparator}'
    '.agent-tasks${Platform.pathSeparator}$id.md',
  );

  test('a projectless capture gets a workspace, a brief and a cwd', () async {
    final ProjectAgentHandoff handoff = handoffWith(
      const <String, Project>{},
      sessionsRoot: () => root,
    );

    final AgentHandoffResult result = await handoff.handoff(_request('cap-1'));

    expect(brief('cap-1').existsSync(), isTrue);
    expect(brief('cap-1').readAsStringSync(), contains('Split the tokenizer'));
    final AgentSessionLaunchRequest launch = launcher.requests.single;
    expect(launch.repoPath, '${root.path}${Platform.pathSeparator}cap-1');
    expect(launch.projectId, 'capture-cap-1');
    expect(launch.projectName, 'Capture');
    expect(result.taskPath, '.agent-tasks/cap-1.md');
    expect(handoff.workspacePathFor('cap-1', null), launch.repoPath);
  });

  test('an empty repoPath and a dangling id both use the workspace', () async {
    final ProjectAgentHandoff handoff = handoffWith(const <String, Project>{
      'empty': Project(id: 'empty', name: 'Empty', repoPath: '  '),
    }, sessionsRoot: () => root);

    await handoff.handoff(_request('cap-a', projectId: 'empty'));
    await handoff.handoff(_request('cap-b', projectId: 'gone'));

    expect(brief('cap-a').existsSync(), isTrue);
    expect(brief('cap-b').existsSync(), isTrue);
  });

  test('a repository-backed project still uses its repository', () async {
    final Directory repo = Directory.systemTemp.createTempSync('repo-');
    addTearDown(() => repo.deleteSync(recursive: true));
    final ProjectAgentHandoff handoff = handoffWith(<String, Project>{
      'p1': Project(id: 'p1', name: 'Acme', repoPath: repo.path),
    }, sessionsRoot: () => root);

    await handoff.handoff(_request('cap-1', projectId: 'p1'));

    expect(launcher.requests.single.repoPath, repo.path);
    expect(root.listSync(), isEmpty);
    expect(handoff.workspacePathFor('cap-1', 'p1'), isNull);
  });

  test('a Command-bound project is still refused', () async {
    final ProjectAgentHandoff handoff = handoffWith(const <String, Project>{
      'p1': Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '',
        commandHost: 'https://command.example',
        commandWorkspace: 'ws',
      ),
    }, sessionsRoot: () => root);

    expect(handoff.agentsFor('p1'), isEmpty);
    await expectLater(
      handoff.handoff(_request('cap-1', projectId: 'p1')),
      throwsA(isA<AgentHandoffUnavailableException>()),
    );
    expect(launcher.requests, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test('two captures never share a session name', () async {
    final ProjectAgentHandoff handoff = handoffWith(
      const <String, Project>{},
      sessionsRoot: () => root,
    );

    await handoff.handoff(_request('0b6f3c1e-1111-4222-8333-444455556666'));
    await handoff.handoff(_request('9d2a7e5f-1111-4222-8333-444455556666'));

    final List<String?> names = launcher.requests
        .map((AgentSessionLaunchRequest r) => r.sessionName)
        .toList();
    expect(names.toSet(), hasLength(2));
    for (final String? name in names) {
      expect(name, matches(RegExp(r'^[a-z0-9-]{1,40}$')));
    }
  });

  test('a second send appends and never deletes the workspace', () async {
    final ProjectAgentHandoff handoff = handoffWith(
      const <String, Project>{},
      sessionsRoot: () => root,
    );

    await handoff.handoff(_request('cap-1'));
    brief('cap-1').writeAsStringSync('\nagent notes', mode: FileMode.append);
    await handoff.handoff(_request('cap-1'));

    final String text = brief('cap-1').readAsStringSync();
    expect(text, contains('agent notes'));
    expect('Split the tokenizer'.allMatches(text), hasLength(2));
  });

  test('offers every agent with no default when a root exists', () {
    final ProjectAgentHandoff handoff = handoffWith(
      const <String, Project>{},
      sessionsRoot: () => root,
    );

    final List<HandoffAgent> agents = handoff.agentsFor(null);
    expect(agents, hasLength(AgentKind.values.length));
    expect(agents.any((HandoffAgent a) => a.isDefault), isFalse);
  });

  test('an empty-repo project keeps its default agent', () {
    final ProjectAgentHandoff handoff = handoffWith(const <String, Project>{
      'p1': Project(
        id: 'p1',
        name: 'Acme',
        repoPath: '',
        defaultAgent: AgentKind.codex,
      ),
    }, sessionsRoot: () => root);

    expect(
      handoff.agentsFor('p1').where((HandoffAgent a) => a.isDefault).single.id,
      'codex',
    );
  });

  test('without a sessions root nothing changes', () async {
    for (final Directory? Function()? resolver in <Directory? Function()?>[
      null,
      () => null,
    ]) {
      final ProjectAgentHandoff handoff = handoffWith(const <String, Project>{
        'empty': Project(id: 'empty', name: 'E', repoPath: ''),
      }, sessionsRoot: resolver);

      expect(handoff.agentsFor(null), isEmpty);
      expect(handoff.agentsFor('empty'), isEmpty);
      expect(handoff.workspacePathFor('cap-1', null), isNull);
      await expectLater(
        handoff.handoff(_request('cap-1')),
        throwsA(isA<AgentHandoffUnavailableException>()),
      );
    }
    expect(launcher.requests, isEmpty);
  });
}

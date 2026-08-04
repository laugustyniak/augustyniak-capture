import 'dart:io';

import 'package:audivoa_core/features/projects/data/projects_repository.dart';
import 'package:audivoa_core/features/projects/domain/agent_session_launcher.dart';
import 'package:audivoa_core/features/projects/domain/project.dart';
import 'package:audivoa_core/features/projects/presentation/projects_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ProjectsRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'audivoa-projects-controller-',
    );
    repository = ProjectsRepository(directoryProvider: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('create, update, select and delete stay durable', () async {
    final ProjectsController controller = ProjectsController(
      repository: repository,
    );
    await controller.initialize();

    final Project first = await controller.create(
      name: '  Audivoa  ',
      repoPath: '  /work/audivoa  ',
      description: '  Voice workflow  ',
      defaultAgent: AgentKind.codex,
    );
    final Project second = await controller.create(
      name: 'Legal AI',
      repoPath: '/work/legal-ai',
    );

    expect(controller.activeProjectId, first.id);
    await controller.select(second.id);
    expect(controller.activeProject, same(second));

    final ProjectsController reloaded = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => directory),
    );
    await reloaded.initialize();
    expect(reloaded.activeProjectId, second.id);

    await controller.update(
      project: first,
      name: 'Audivoa Core',
      repoPath: first.repoPath,
      sessionName: 'audivoa',
      defaultAgent: AgentKind.gemini,
    );
    await controller.delete(second.id);

    final List<Project> stored = await repository.loadAll();
    expect(stored, hasLength(1));
    expect(stored.single.name, 'Audivoa Core');
    expect(stored.single.repoPath, '/work/audivoa');
    expect(stored.single.sessionName, 'audivoa');
    expect(stored.single.defaultAgent, AgentKind.gemini);
    expect(controller.activeProjectId, isNull);
  });

  test('launch maps project settings into a structured request', () async {
    final _CapturingLauncher launcher = _CapturingLauncher();
    final ProjectsController controller = ProjectsController(
      repository: repository,
      launcher: launcher,
    );
    const Project project = Project(
      id: 'audivoa',
      name: 'Audivoa',
      repoPath: '/work/audivoa',
      sessionName: 'audivoa-work',
      agentSettings: <AgentKind, AgentSettings>{
        AgentKind.claudeCode: AgentSettings(
          additionalArgs: <String>['--model', 'sonnet'],
          initialPrompt: 'Read AGENTS.md.',
        ),
      },
    );

    await controller.launch(project, AgentKind.claudeCode);

    final AgentSessionLaunchRequest request = launcher.requests.single;
    expect(request.projectId, 'audivoa');
    expect(request.projectName, 'Audivoa');
    expect(request.repoPath, '/work/audivoa');
    expect(request.sessionName, 'audivoa-work');
    expect(request.agent, ProjectAgent.claude);
    expect(request.arguments, <String>['--model', 'sonnet', 'Read AGENTS.md.']);
    expect(controller.isLaunching(project.id, AgentKind.claudeCode), isFalse);
  });

  test('failed save does not replace in-memory state', () async {
    final ProjectsController controller = ProjectsController(
      repository: _FailingRepository(directory),
    );
    await controller.initialize();

    await expectLater(
      controller.create(name: 'Audivoa', repoPath: '/work/audivoa'),
      throwsA(isA<FileSystemException>()),
    );

    expect(controller.projects, isEmpty);
    expect(controller.error, isNotNull);
  });
}

class _CapturingLauncher implements AgentSessionLauncher {
  final List<AgentSessionLaunchRequest> requests =
      <AgentSessionLaunchRequest>[];

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    requests.add(request);
    return const AgentSessionLaunchResult(
      sessionName: 'test-session',
      attachedToExistingSession: false,
    );
  }
}

class _FailingRepository extends ProjectsRepository {
  _FailingRepository(Directory directory)
    : super(directoryProvider: () async => directory);

  @override
  Future<void> saveAll(List<Project> projects, {String? activeProjectId}) {
    throw const FileSystemException('disk full');
  }
}

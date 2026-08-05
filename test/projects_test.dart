import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Project', () {
    test('JSON round-trip preserves launch context', () {
      const Project original = Project(
        id: 'augustyniak-capture',
        name: 'Augustyniak Capture',
        repoPath: '/work/augustyniak-capture',
        description: 'Voice capture workflow',
        sessionName: 'augustyniak-capture',
        defaultAgent: AgentKind.codex,
        agentSettings: <AgentKind, AgentSettings>{
          AgentKind.codex: AgentSettings(
            additionalArgs: <String>['--search'],
            initialPrompt: 'Read AGENTS.md first.',
          ),
          AgentKind.claudeCode: AgentSettings(
            additionalArgs: <String>['--model', 'sonnet'],
          ),
        },
      );

      final Project restored = Project.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.repoPath, original.repoPath);
      expect(restored.description, original.description);
      expect(restored.sessionName, original.sessionName);
      expect(restored.defaultAgent, AgentKind.codex);
      expect(restored.settingsFor(AgentKind.codex).additionalArgs, <String>[
        '--search',
      ]);
      expect(
        restored.settingsFor(AgentKind.codex).initialPrompt,
        'Read AGENTS.md first.',
      );
    });

    test('partial and future JSON degrades optional values safely', () {
      final Project restored = Project.fromJson(<String, dynamic>{
        'id': 'future',
        'name': 42,
        'repoPath': null,
        'description': <String>['invalid'],
        'defaultAgent': 'futureAgent',
        'agentSettings': <String, dynamic>{
          'codex': <String, dynamic>{
            'additionalArgs': <dynamic>['--safe', 7],
            'initialPrompt': false,
          },
          'futureAgent': <String, dynamic>{'additionalArgs': <String>[]},
        },
        'futureField': true,
      });

      expect(restored.name, 'Project');
      expect(restored.repoPath, '');
      expect(restored.description, isNull);
      expect(restored.defaultAgent, isNull);
      expect(restored.settingsFor(AgentKind.codex).additionalArgs, <String>[
        '--safe',
      ]);
      expect(restored.settingsFor(AgentKind.codex).initialPrompt, isNull);
      expect(restored.agentSettings, hasLength(1));
    });

    test('legacy agent names and args spelling remain readable', () {
      final Project restored = Project.fromJson(<String, dynamic>{
        'id': 'legacy',
        'defaultAgent': 'gemini',
        'agentSettings': <String, dynamic>{
          'claude': <String, dynamic>{
            'args': <String>['--verbose'],
          },
          'gemini': <String, dynamic>{
            'args': <String>['--model', 'gemini-2.5-pro'],
          },
        },
      });

      expect(restored.defaultAgent, AgentKind.antigravity);
      expect(
        restored.settingsFor(AgentKind.claudeCode).additionalArgs,
        <String>['--verbose'],
      );
      expect(
        restored.settingsFor(AgentKind.antigravity).additionalArgs,
        <String>['--model', 'gemini-2.5-pro'],
      );
    });

    test('missing or blank id is rejected', () {
      expect(
        () => Project.fromJson(<String, dynamic>{}),
        throwsFormatException,
      );
      expect(
        () => Project.fromJson(<String, dynamic>{'id': '  '}),
        throwsFormatException,
      );
    });
  });

  group('ProjectsRepository', () {
    late Directory temporaryDirectory;
    late ProjectsRepository repository;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'augustyniak-capture-projects-test-',
      );
      repository = ProjectsRepository(
        directoryProvider: () async => temporaryDirectory,
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('missing index loads as an empty collection', () async {
      expect(await repository.loadAll(), isEmpty);
    });

    test('saveAll atomically round-trips projects', () async {
      const List<Project> projects = <Project>[
        Project(
          id: 'one',
          name: 'One',
          repoPath: '/repos/one',
          defaultAgent: AgentKind.antigravity,
        ),
        Project(id: 'two', name: 'Two', repoPath: '/repos/two'),
      ];

      await repository.saveAll(projects, activeProjectId: 'two');

      final File file = await repository.projectsFile();
      expect(await file.exists(), isTrue);
      expect(await File('${file.path}.tmp').exists(), isFalse);
      final List<Project> restored = await repository.loadAll();
      expect(restored.map((Project item) => item.id), <String>['one', 'two']);
      expect(restored.first.defaultAgent, AgentKind.antigravity);
      expect(repository.loadedActiveProjectId, 'two');
    });

    test('loads a future versioned wrapper', () async {
      final File file = await repository.projectsFile();
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'schemaVersion': 2,
          'projects': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'wrapped',
              'name': 'Wrapped',
              'repoPath': '/repo',
            },
          ],
        }),
      );

      final List<Project> restored = await repository.loadAll();
      expect(restored.single.id, 'wrapped');
    });

    test('drops malformed rows but preserves a partial backup', () async {
      final File file = await repository.projectsFile();
      await file.writeAsString(
        jsonEncode(<dynamic>[
          <String, dynamic>{
            'id': 'valid',
            'name': 'Valid',
            'repoPath': '/repo',
          },
          <String, dynamic>{'name': 'Missing id'},
          'not an object',
        ]),
      );

      final List<Project> restored = await repository.loadAll();

      expect(restored.single.id, 'valid');
      expect(
        temporaryDirectory.listSync().whereType<File>().map(
          (File item) => item.path,
        ),
        contains(matches(RegExp(r'projects\.partial-.*\.json$'))),
      );
    });

    test('malformed top-level JSON throws and preserves a backup', () async {
      final File file = await repository.projectsFile();
      await file.writeAsString('{broken');

      await expectLater(
        repository.loadAll(),
        throwsA(isA<ProjectsIndexUnreadableException>()),
      );
      expect(
        temporaryDirectory.listSync().whereType<File>().map(
          (File item) => item.path,
        ),
        contains(matches(RegExp(r'projects\.corrupt-.*\.json$'))),
      );
    });
  });
}

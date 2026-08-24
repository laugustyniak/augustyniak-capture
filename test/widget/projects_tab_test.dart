import 'dart:io';

import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/projects/data/directory_picker.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_controller.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Waits for real filesystem work started inside the fake-async zone by asking
/// whether it has landed, rather than by counting rounds. A project save is a
/// chain — the JSON write, the rename, the SQLite mirror — and a round costs
/// whatever the machine gives it, so a fixed count measures the machine and not
/// the save. At 24 rounds this failed roughly one idle run in three and passed
/// under full-suite load, where every round takes long enough for the IO to win
/// the race. Same rule `_until` encodes in `recording_limit_test.dart`, with the
/// polarity inverted: there a busy machine broke a fixed span, here an idle one
/// does. The bound is a backstop, not a schedule — a run that meets the
/// condition on the first check pays for one round.
Future<void> _untilIo(
  WidgetTester tester,
  bool Function() condition, {
  int maxRounds = 200,
}) async {
  for (int i = 0; i < maxRounds && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory directory;
  late ProjectsController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'augustyniak-capture-projects-ui-',
    );
    controller = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => directory),
    );
    await controller.initialize();
    await controller.create(
      name: 'Augustyniak Capture',
      repoPath: '/work/augustyniak-capture',
    );
  });

  tearDown(() async {
    controller.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('renders a durable project and opens its editor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) =>
                ProjectsTab(controller: controller),
          ),
        ),
      ),
    );

    expect(find.text('Augustyniak Capture'), findsOneWidget);
    expect(find.text('/work/augustyniak-capture'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('CODEX'), findsOneWidget);
    expect(find.text('CLAUDE CODE'), findsOneWidget);
    expect(find.text('ANTIGRAVITY'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('add-project')));
    // The autofocus cursor blinks forever, so this sheet never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add project'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('project-repo-path-field')),
      findsOneWidget,
    );

    // Close the route explicitly so the focused editable text and its cursor
    // ticker do not outlive the test binding during finalization.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('the folder dialog fills the repository path field', (
    WidgetTester tester,
  ) async {
    final _FakeDirectoryPicker picker = _FakeDirectoryPicker(
      chosen: '/work/picked',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) =>
                ProjectsTab(controller: controller, directoryPicker: picker),
          ),
        ),
      ),
    );

    // Editing an existing project, so the sheet opens unfocused and the dialog
    // starts at the path already stored.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(
      find.byKey(const ValueKey<String>('project-repo-path-browse')),
    );
    await tester.pump();

    expect(picker.initialDirectories, <String?>['/work/augustyniak-capture']);
    final TextFormField field = tester.widget<TextFormField>(
      find.byKey(const ValueKey<String>('project-repo-path-field')),
    );
    expect(field.controller!.text, '/work/picked');

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a picker the platform cannot offer draws no browse button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) => ProjectsTab(
              controller: controller,
              directoryPicker: _FakeDirectoryPicker(available: false),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('project-repo-path-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('project-repo-path-browse')),
      findsNothing,
    );

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('binding walks two pickers and stores the pair', (
    WidgetTester tester,
  ) async {
    final _FakeCommandClient client = _FakeCommandClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) =>
                ProjectsTab(controller: controller, commandClient: client),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The sheet has its own scrollable on top of the tab's list, so the target
    // has to be named — `scrollUntilVisible` refuses to guess between two.
    await tester.scrollUntilVisible(
      find.text('COMMAND BINDING'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(find.text('Not bound — work stays local.'), findsOneWidget);

    await tester.tap(find.text('HOSTS'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Studio (macOS)'), findsOneWidget);

    await tester.tap(find.text('Studio (macOS)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Workspaces are read for the host that was picked, never listed globally.
    expect(client.workspacesFor, <String>['studio']);

    await tester.tap(find.text('capture'));
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('save-project')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('save-project')),
      warnIfMissed: true,
    );
    // Saving writes `projects.json`, which is real IO the fake-async zone does
    // not pump. Wait for the binding to actually be there rather than for a
    // number of rounds to go by.
    await _untilIo(
      tester,
      () => controller.projects.single.commandHost != null,
    );

    final Project saved = controller.projects.single;
    expect(saved.commandHost, 'studio');
    expect(saved.commandWorkspace, 'capture');
    expect(saved.isBoundToCommand, isTrue);
    expect(saved.commandBoundAt, isNotNull);
  });

  testWidgets('an unconfigured control plane says so instead of hiding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) => ProjectsTab(
              controller: controller,
              commandClient: _FakeCommandClient(configured: false),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The sheet has its own scrollable on top of the tab's list, so the target
    // has to be named — `scrollUntilVisible` refuses to guess between two.
    await tester.scrollUntilVisible(
      find.text('COMMAND BINDING'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    expect(find.textContaining('No control plane configured'), findsOneWidget);
    expect(find.text('HOSTS'), findsNothing);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

}

/// Answers from a table instead of a control plane, and records which host it
/// was asked about — the fake that proves the picker asks per host rather than
/// listing everything once.
class _FakeCommandClient implements CommandClient {
  _FakeCommandClient({this.configured = true});

  final bool configured;
  final List<String> workspacesFor = <String>[];

  @override
  bool get isConfigured => configured;

  @override
  Future<List<CommandHost>> hosts() async => const <CommandHost>[
    CommandHost(id: 'studio', label: 'Studio (macOS)'),
    CommandHost(id: 'rack-01', label: 'Rack 01'),
  ];

  @override
  Future<List<CommandWorkspace>> workspaces(String hostId) async {
    workspacesFor.add(hostId);
    return <CommandWorkspace>[
      CommandWorkspace(name: hostId == 'studio' ? 'capture' : 'command'),
    ];
  }

  // Binding never delivers anything, so the two writes are out of this fake's
  // scope — reaching them from the project editor would itself be the bug.
  @override
  Future<CommandBrief> putBrief({
    required String host,
    required String workspace,
    required String captureId,
    required String content,
  }) async => throw UnimplementedError();

  @override
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  }) async => throw UnimplementedError();

  @override
  Future<CommandBriefStatus> briefStatus(String briefId) async =>
      throw UnimplementedError();
}


/// Stands in for the native folder dialog, the way `_FakeRegistrar` stands in
/// for the OS hotkey table — the widget suite must not reach `file_picker`.
class _FakeDirectoryPicker implements DirectoryPicker {
  _FakeDirectoryPicker({this.chosen, this.available = true});

  final String? chosen;
  final bool available;
  final List<String?> initialDirectories = <String?>[];

  @override
  bool get isAvailable => available;

  @override
  Future<String?> pick({String? initialDirectory}) async {
    initialDirectories.add(initialDirectory);
    return chosen;
  }
}

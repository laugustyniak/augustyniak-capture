import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/directory_picker.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_controller.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ProjectsController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('audivoa-projects-ui-');
    controller = ProjectsController(
      repository: ProjectsRepository(directoryProvider: () async => directory),
    );
    await controller.initialize();
    await controller.create(name: 'Audivoa', repoPath: '/work/audivoa');
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

    expect(find.text('Audivoa'), findsOneWidget);
    expect(find.text('/work/audivoa'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('CODEX'), findsOneWidget);
    expect(find.text('CLAUDE CODE'), findsOneWidget);
    expect(find.text('GEMINI'), findsOneWidget);

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

    expect(picker.initialDirectories, <String?>['/work/audivoa']);
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

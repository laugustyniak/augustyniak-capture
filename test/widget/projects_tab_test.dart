import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_controller.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

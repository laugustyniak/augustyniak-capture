import 'dart:io';

import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_controller.dart';
import 'package:augustyniak_capture/features/projects/presentation/projects_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late Directory tempDir;
  late ProjectsController projectsController;
  late RecordingsController recordingsController;
  late String projectId;
  late String captureId;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-captures-sheet-test-',
    );
    projectsController = ProjectsController(
      repository: ProjectsRepository(
        directoryProvider: () async => tempDir,
      ),
    );
    await projectsController.initialize();
    await projectsController.create(
      name: 'Test Project',
      repoPath: '/work/test-project',
    );
    projectId = projectsController.projects.first.id;

    recordingsController = await buildRecordingsController(tempDir);

    // Seeded here rather than in the test body, and that is not tidiness:
    // `addTextNote` writes a real `.txt` and persists the index, and a
    // `testWidgets` body runs in a fake-async zone that never pumps the real
    // event loop — so an await on that IO simply never resumes and the test
    // hangs to its ten-minute timeout instead of failing. `setUp` runs outside
    // that zone, which is where filesystem work belongs.
    await recordingsController.addTextNote(
      'Fix landing page responsive layout',
    );
    captureId = recordingsController.recordings.first.id;
    await recordingsController.setProject(captureId, projectId);
    await recordingsController.waitForProcessing();
  });

  tearDown(() async {
    projectsController.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('tapping project card opens project captures sheet', (
    WidgetTester tester,
  ) async {
    bool queueNavigated = false;
    String? navigatedProjectId;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ProjectsTab(
            controller: projectsController,
            recordingsController: recordingsController,
            onNavigateToQueue: (String id) {
              queueNavigated = true;
              navigatedProjectId = id;
            },
          ),
        ),
      ),
    );

    expect(find.text('Test Project'), findsOneWidget);
    expect(find.text('CAPTURES (1)'), findsOneWidget);

    // Tap on the captures button or project card
    await tester.tap(find.text('CAPTURES (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify sheet opened
    expect(find.text('PROJECT CAPTURES'), findsOneWidget);
    expect(find.text('Fix landing page responsive layout'), findsOneWidget);

    // Tap "VIEW ALL IN QUEUE TAB" button inside sheet
    await tester.tap(find.byKey(const ValueKey<String>('open-in-queue-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(queueNavigated, isTrue);
    expect(navigatedProjectId, projectId);
  });
}

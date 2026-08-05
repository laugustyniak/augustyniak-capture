import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/handoff_sheet.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _FakeLauncher implements AgentSessionLauncher {
  _FakeLauncher({this.attach = false});

  final bool attach;
  final List<AgentSessionLaunchRequest> requests = <AgentSessionLaunchRequest>[];

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    requests.add(request);
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
    appDir = Directory.systemTemp.createTempSync('augustyniak-sheet-app-');
    repo = Directory.systemTemp.createTempSync('augustyniak-sheet-repo-');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    repo.deleteSync(recursive: true);
  });

  Future<RecordingsController> controllerWith(
    AgentSessionLauncher launcher, {
    AgentKind? defaultAgent,
  }) => buildRecordingsController(
    appDir,
    seed: <Recording>[
      makeRecording(
        id: 'r1',
        projectId: 'p1',
        title: 'Add the delegate button',
        transcript: 'Dictate a note, then hand it to an agent.',
      ),
    ],
    agentHandoff: ProjectAgentHandoff(
      projectById: (String id) => id == 'p1'
          ? Project(
              id: 'p1',
              name: 'Acme',
              repoPath: repo.path,
              defaultAgent: defaultAgent,
            )
          : null,
      launcher: launcher,
    ),
  );

  /// A handoff writes the brief to the real filesystem and the fake-async zone
  /// does not pump that work, so the launch has to be settled explicitly. Ten
  /// rounds because the chain is long: stat the repo, stat the brief, create the
  /// directory, append, launch, then persist the closed capture.
  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// Opens the sheet from a host that has a Navigator, the way the queue does.
  Future<void> openSheet(
    WidgetTester tester,
    RecordingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showHandoffSheet(
              context,
              controller: controller,
              recording: controller.recordings.single,
              projectName: 'Acme',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sheet opens on the project default and launches it', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await controllerWith(
      launcher,
      defaultAgent: AgentKind.antigravity,
    );

    await openSheet(tester, controller);

    // The prompt shown is the pointer to the brief, not the transcript.
    expect(find.text('ANTIGRAVITY'), findsOneWidget);
    expect(
      find.text('Read .agent-tasks/r1.md and start on the task described there.'),
      findsOneWidget,
    );

    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    // Preselected default means one tap: the launch used Antigravity without
    // the user touching the chips.
    expect(launcher.requests.single.agent, ProjectAgent.antigravity);
    // A new session received the prompt, so there is nothing left to say.
    expect(find.text('LAUNCH SESSION'), findsNothing);
    expect(controller.recordings.single.isProcessedByUser, isTrue);
  });

  testWidgets('choosing another agent overrides the project default', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await controllerWith(
      launcher,
      defaultAgent: AgentKind.codex,
    );

    await openSheet(tester, controller);
    await tester.tap(find.text('CLAUDE CODE'));
    await tester.pump();
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    expect(launcher.requests.single.agent, ProjectAgent.claude);
  });

  testWidgets('an attach keeps the sheet open and says the prompt did not land',
      (WidgetTester tester) async {
    final _FakeLauncher launcher = _FakeLauncher(attach: true);
    final RecordingsController controller = await controllerWith(launcher);

    await openSheet(tester, controller);
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    // The one outcome that looks like success and is not finished: the session
    // was reattached, so the running agent never saw this prompt.
    expect(find.text('That session was already running'), findsOneWidget);
    expect(find.textContaining('never received this prompt'), findsOneWidget);
    // Still open, with the prompt on hand to paste.
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('an edited prompt is the one that launches', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await controllerWith(launcher);

    await openSheet(tester, controller);
    await tester.enterText(
      find.byType(TextField),
      'Read the brief and only write tests.',
    );
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    expect(launcher.requests.single.arguments, <String>[
      'Read the brief and only write tests.',
    ]);
  });

  testWidgets('a capture with no project opens no sheet at all', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[makeRecording(id: 'r1', transcript: 'Body.')],
    );

    await openSheet(tester, controller);

    expect(find.text('Hand off to an agent'), findsNothing);
  });
}

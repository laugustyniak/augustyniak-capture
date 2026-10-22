import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/agent_session_launcher.dart';
import 'package:augustyniak_capture/features/projects/domain/native_agent_types.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/project_agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/assistant_target.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_sender.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/handoff_sheet.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _FakeLauncher implements AgentSessionLauncher {
  _FakeLauncher({this.running = false, this.attachFailure, this.job});

  /// The session already exists, so a launch attaches instead of starting.
  final bool running;
  final String? attachFailure;
  final NativeAgentJobHandle? job;
  final List<AgentSessionLaunchRequest> requests =
      <AgentSessionLaunchRequest>[];
  final List<String> attached = <String>[];

  @override
  Future<AgentSessionLaunchResult> launch(
    AgentSessionLaunchRequest request,
  ) async {
    requests.add(request);
    return AgentSessionLaunchResult(
      sessionName: 'augustyniak-acme-p1-${request.agent.executable}',
      attachedToExistingSession: running,
      detached: request.detached,
      job: job,
    );
  }

  @override
  Future<void> attach(String sessionName) async {
    if (attachFailure != null) {
      throw AgentSessionLaunchException(attachFailure!);
    }
    attached.add(sessionName);
  }
}

/// Offers a fixed list and records what it was asked to send.
class _FakeSender implements CaptureSender {
  _FakeSender({this.copied = false, this.fail = false});

  final bool copied;
  final bool fail;
  bool dismissNext = false;
  final List<({SendTarget target, String prompt})> calls =
      <({SendTarget target, String prompt})>[];

  @override
  Future<List<SendTarget>> availableTargets() async => <SendTarget>[
    const AssistantSendTarget(AssistantTarget.claudeDesktop),
    const AssistantSendTarget(AssistantTarget.claudeWeb),
    const AssistantSendTarget(AssistantTarget.chatgpt),
    const AssistantSendTarget(AssistantTarget.gemini),
    const CopySendTarget(),
  ];

  @override
  Future<SendOutcome?> send(
    RoutedCapture capture,
    SendTarget target,
    String prompt,
  ) async {
    calls.add((target: target, prompt: prompt));
    if (dismissNext) {
      dismissNext = false;
      return null;
    }
    if (fail) {
      throw const AssistantUnavailableException(AssistantTarget.chatgpt);
    }
    return SendOutcome(
      record: RouteRecord(
        at: DateTime.utc(2026, 10, 6),
        kind: RouteKind.assistant,
        target: 'ChatGPT · web',
      ),
      copiedToClipboard: copied,
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
    Set<AgentKind> skipPermissions = const <AgentKind>{},
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
              agentSettings: <AgentKind, AgentSettings>{
                for (final AgentKind agent in skipPermissions)
                  agent: const AgentSettings(skipPermissions: true),
              },
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

    // The prompt shown is the capture itself — what the agent will be started
    // on — and the file is named underneath as the copy, not as the payload.
    expect(find.text('ANTIGRAVITY'), findsOneWidget);
    expect(
      find.text('Dictate a note, then hand it to an agent.'),
      findsOneWidget,
    );
    expect(find.textContaining('.agent-tasks/r1.md'), findsOneWidget);

    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    // Preselected default means one tap: the launch used Antigravity without
    // the user touching the chips.
    expect(launcher.requests.single.agent, ProjectAgent.antigravity);
    // A new session received the prompt, so there is nothing left to say.
    expect(find.text('LAUNCH SESSION'), findsNothing);
    expect(controller.recordings.single.isProcessedByUser, isTrue);
  });

  const Key approvalsOff = ValueKey<String>('handoff-approvals-off');
  const String approvalsCopy =
      'Runs with tool approvals off: the agent acts on this text without asking.';

  testWidgets('a default agent with approvals off is flagged in the sheet', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerWith(
      _FakeLauncher(),
      defaultAgent: AgentKind.codex,
      skipPermissions: <AgentKind>{AgentKind.codex},
    );

    await openSheet(tester, controller);

    expect(find.byKey(approvalsOff), findsOneWidget);
    expect(find.text('APPROVALS OFF'), findsOneWidget);
    expect(find.textContaining(approvalsCopy), findsOneWidget);
  });

  testWidgets('no flag, no approvals-off marker', (WidgetTester tester) async {
    final RecordingsController controller = await controllerWith(
      _FakeLauncher(),
      defaultAgent: AgentKind.codex,
    );

    await openSheet(tester, controller);

    expect(find.byKey(approvalsOff), findsNothing);
    expect(find.textContaining('tool approvals off'), findsNothing);
  });

  testWidgets('switching to an agent with the flag shows the marker', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerWith(
      _FakeLauncher(),
      defaultAgent: AgentKind.codex,
      skipPermissions: <AgentKind>{AgentKind.claudeCode},
    );

    await openSheet(tester, controller);
    expect(find.byKey(approvalsOff), findsNothing);

    await tester.tap(find.text('CLAUDE CODE'));
    await tester.pump();
    expect(find.byKey(approvalsOff), findsOneWidget);

    await tester.tap(find.text('CODEX'));
    await tester.pump();
    expect(find.byKey(approvalsOff), findsNothing);
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

  testWidgets(
    'an attach keeps the sheet open and says the prompt did not land',
    (WidgetTester tester) async {
      final _FakeLauncher launcher = _FakeLauncher(running: true);
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
    },
  );

  testWidgets('launches in the background by default and offers the way in', (
    WidgetTester tester,
  ) async {
      final _FakeLauncher launcher = _FakeLauncher();
      final RecordingsController controller = await controllerWith(launcher);

      await openSheet(tester, controller);
      await tester.tap(find.text('LAUNCH SESSION'));
      await settleIo(tester);

      final String session =
          'augustyniak-acme-p1-${launcher.requests.single.agent.executable}';
      expect(launcher.requests.single.detached, isTrue);
      // Stays open: with no window, the sheet is the only thing that says
      // where the session went and how to reach it.
      expect(find.text('Session started in the background'), findsOneWidget);
      expect(find.text('zellij attach $session'), findsOneWidget);
      // The capture is closed — the prompt was delivered.
      expect(controller.recordings.single.isProcessedByUser, isTrue);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('handoff-attach')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('handoff-attach')));
      await settleIo(tester);

      expect(launcher.attached, <String>[session]);
      expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('a native background handoff shows the durable job notice', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher(
      job: const NativeAgentJobHandle(
        id: '00000000-0000-4000-8000-000000000001',
        backend: NativeAgentBackend.codex,
      ),
  );
    final RecordingsController controller = await controllerWith(launcher);

    await openSheet(tester, controller);
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    expect(
      find.byKey(const ValueKey<String>('handoff-native-job-notice')),
      findsOneWidget,
    );
    expect(find.text('Background job accepted the prompt'), findsOneWidget);
    expect(find.textContaining('zellij attach'), findsNothing);
  });

  testWidgets('Gemini explains that background jobs are unavailable', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await controllerWith(
      _FakeLauncher(),
      defaultAgent: AgentKind.geminiCli,
    );

    await openSheet(tester, controller);

    expect(
      find.byKey(const ValueKey<String>('gemini-native-unavailable')),
      findsOneWidget,
    );
    expect(find.text('LAUNCH SESSION'), findsOneWidget);
  });

  testWidgets('IN A WINDOW launches through the terminal and closes', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher();
    final RecordingsController controller = await controllerWith(launcher);

    await openSheet(tester, controller);
    await tester.tap(find.text('IN A WINDOW'));
    await tester.pump();
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    expect(launcher.requests.single.detached, isFalse);
    expect(find.text('LAUNCH SESSION'), findsNothing);
  });

  testWidgets('a failed attach says why and keeps the sheet open', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher(
      attachFailure: 'Session `augustyniak-acme-p1-codex` is not running.',
    );
    final RecordingsController controller = await controllerWith(launcher);

    await openSheet(tester, controller);
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('handoff-attach')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('handoff-attach')));
    await settleIo(tester);

    expect(launcher.attached, isEmpty);
    expect(find.textContaining('is not running'), findsOneWidget);
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
    await tester.ensureVisible(find.text('LAUNCH SESSION'));
    await tester.tap(find.text('LAUNCH SESSION'));
    await settleIo(tester);

    // Framed at launch (#306): the edited text is inside the fence.
    expect(
      launcher.requests.single.prompt,
      startsWith('The user handed you a capture'),
    );
    expect(
      launcher.requests.single.prompt,
      contains(
        '\nRead the brief and only write tests.\n--- END CAPTURE TEXT ---',
      ),
    );
  });

  Future<RecordingsController> projectless(CaptureSender sender) =>
      buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'r1', transcript: 'Ask the assistant about this.'),
        ],
        captureSender: sender,
      );

  testWidgets('a capture with no project shows Web and Copy and no Terminal', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(_FakeSender());

    await openSheet(tester, controller);

    expect(find.text('Send to…'), findsOneWidget);
    expect(find.text('TERMINAL'), findsNothing);
    expect(find.text('LAUNCH SESSION'), findsNothing);
    expect(find.text('WEB'), findsOneWidget);
    expect(find.text('COPY'), findsOneWidget);
    // The prompt is the capture's own text even with no handoff configured.
    expect(find.text('Ask the assistant about this.'), findsOneWidget);
    // Where it goes is on the button, and what it does on arrival with it.
    expect(find.textContaining('chatgpt.com'), findsOneWidget);
    expect(find.textContaining('sends immediately'), findsWidgets);
    expect(find.textContaining('gemini.google.com'), findsOneWidget);
  });

  testWidgets(
    'a web send keeps the sheet open with Mark done and Keep on desk',
    (WidgetTester tester) async {
      final _FakeSender sender = _FakeSender();
      final RecordingsController controller = await projectless(sender);

      await openSheet(tester, controller);
      await tester.enterText(find.byType(TextField), 'Edited question');
      await tester.tap(find.text('ChatGPT'));
      await tester.pumpAndSettle();

      expect(sender.calls.single.prompt, 'Edited question');
      expect(find.text('Sent to ChatGPT · web'), findsOneWidget);
      expect(find.textContaining('Prompt copied'), findsNothing);
      expect(find.text('MARK DONE'), findsOneWidget);
      expect(find.text('KEEP ON DESK'), findsOneWidget);
      // Recorded, and still on the desk.
      expect(
        controller.recordings.single.routes.single.kind,
        RouteKind.assistant,
      );
      expect(controller.recordings.single.isProcessedByUser, isFalse);
    },
  );

  testWidgets('a send that needed the clipboard says to paste', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(
      _FakeSender(copied: true),
    );

    await openSheet(tester, controller);
    await tester.tap(find.text('Gemini'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Prompt copied — paste it into'),
      findsOneWidget,
    );
    // Nothing was sent: a page was opened and the prompt waits on the
    // clipboard, so the headline must not claim a delivery.
    expect(find.text('Opened ChatGPT · web'), findsOneWidget);
    expect(find.textContaining('Sent to'), findsNothing);
  });

  testWidgets('the Claude Desktop tile names the app, not a website', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(_FakeSender());

    await openSheet(tester, controller);

    expect(
      find.text('desktop app · opens with the prompt filled in'),
      findsOneWidget,
    );
  });

  testWidgets('Mark done closes the item and the sheet', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(_FakeSender());

    await openSheet(tester, controller);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MARK DONE'));
    await tester.pumpAndSettle();

    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(find.text('Send to…'), findsNothing);
  });

  testWidgets('Keep on desk closes only the sheet', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(_FakeSender());

    await openSheet(tester, controller);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KEEP ON DESK'));
    await tester.pumpAndSettle();

    expect(find.text('Send to…'), findsNothing);
    expect(controller.recordings.single.isProcessedByUser, isFalse);
  });

  testWidgets('a failed send shows the error and no Mark done', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await projectless(
      _FakeSender(fail: true),
    );

    await openSheet(tester, controller);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open ChatGPT'), findsOneWidget);
    expect(find.text('MARK DONE'), findsNothing);
    expect(controller.recordings.single.routes, isEmpty);
  });

  testWidgets('a send that could not be recorded still says it was sent', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1', transcript: 'Body.')],
        saveError: const FileSystemException('disk full'),
      ),
      captureSender: _FakeSender(),
    );

    await openSheet(tester, controller);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();

    expect(find.text('Sent to ChatGPT · web'), findsOneWidget);
    expect(find.textContaining('not recorded'), findsOneWidget);
    // Not stuck busy: the targets still answer a tap.
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();
    expect(find.text('Sent to ChatGPT · web'), findsOneWidget);
  });

  testWidgets('a dismissed share after a failure shows no error', (
    WidgetTester tester,
  ) async {
    final _FakeSender sender = _FakeSender(fail: true);
    final RecordingsController controller = await projectless(sender);

    await openSheet(tester, controller);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not open ChatGPT'), findsOneWidget);

    sender.dismissNext = true;
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open'), findsNothing);
  });

  testWidgets('with a project the Terminal group sits beside the others', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: ProjectAgentHandoff(
        projectById: (String id) =>
            Project(id: 'p1', name: 'Acme', repoPath: repo.path),
        launcher: _FakeLauncher(),
      ),
      captureSender: _FakeSender(),
    );

    await openSheet(tester, controller);

    expect(find.text('TERMINAL'), findsOneWidget);
    expect(find.text('LAUNCH SESSION'), findsOneWidget);
    expect(find.text('WEB'), findsOneWidget);
  });

  testWidgets(
    'a projectless capture with a scratch root gets a Terminal group',
    (WidgetTester tester) async {
      final Directory sessions = Directory('${appDir.path}/sessions');
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1', transcript: 'Body.')],
        agentHandoff: ProjectAgentHandoff(
          projectById: (String id) => null,
          launcher: _FakeLauncher(),
          sessionsRoot: () => sessions,
        ),
        captureSender: _FakeSender(),
      );

      await openSheet(tester, controller);

      expect(find.text('TERMINAL'), findsOneWidget);
      expect(find.text('LAUNCH SESSION'), findsOneWidget);
      expect(
        find.textContaining('Runs in a scratch folder: ${sessions.path}'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a repository-backed capture shows no scratch note', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: 'Body.'),
      ],
      agentHandoff: ProjectAgentHandoff(
        projectById: (String id) =>
            Project(id: 'p1', name: 'Acme', repoPath: repo.path),
        launcher: _FakeLauncher(),
        sessionsRoot: () => Directory('${appDir.path}/sessions'),
      ),
      captureSender: _FakeSender(),
    );

    await openSheet(tester, controller);

    expect(find.text('TERMINAL'), findsOneWidget);
    expect(find.textContaining('scratch folder'), findsNothing);
  });
}

import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/intent_classifier.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/smart_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Router implements CaptureRouter {
  _Router({this.available = true, this.failure});

  final bool available;
  final String? failure;
  int routed = 0;

  @override
  bool canRoute(String? projectId) => available;

  @override
  RouteKind? resolvedKind(RoutedCapture capture) =>
      available ? RouteKind.file : null;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    if (failure != null) throw FileSystemException(failure!);
    routed++;
    return RouteRecord(at: DateTime.now(), kind: RouteKind.file, target: 'inbox');
  }
}

class _Handoff implements AgentHandoff {
  _Handoff({
    this.agents = const <HandoffAgent>[
      HandoffAgent(id: 'claudeCode', label: 'Claude Code', isDefault: true),
    ],
    this.failure,
  });

  final List<HandoffAgent> agents;
  final String? failure;
  final List<AgentHandoffRequest> requests = <AgentHandoffRequest>[];

  @override
  List<HandoffAgent> agentsFor(String? projectId) => agents;

  @override
  String taskPathFor(String captureId) => '.agent-tasks/$captureId.md';

  @override
  String? workspacePathFor(String captureId, String? projectId) => null;

  @override
  String promptFor(RoutedCapture capture) => capture.body;

  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async {
    if (failure != null) throw FileSystemException(failure!);
    requests.add(request);
    return AgentHandoffResult(
      record: RouteRecord(
        at: DateTime.now(),
        kind: RouteKind.agent,
        target: 'Claude Code · s',
      ),
      taskPath: taskPathFor(request.captureId),
      sessionName: 's',
      attachedToExistingSession: false,
      detached: request.detached,
    );
  }

  @override
  Future<void> attach(String sessionName) async {}
}

class _Classifier implements IntentClassifier {
  _Classifier(this.answer, {this.fails = false});

  final SmartIntent answer;
  final bool fails;
  int calls = 0;
  Set<SmartIntent>? lastOffered;

  @override
  Future<SmartIntentDecision> classify(
    String text, {
    required Set<SmartIntent> offered,
  }) async {
    calls++;
    lastOffered = offered;
    if (fails) throw const SocketException('down');
    return SmartIntentDecision(intent: answer, fromModel: true);
  }
}

void main() {
  late Directory appDir;
  setUp(() => appDir = Directory.systemTemp.createTempSync('smart-route-'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<RecordingsController> build({
    required _Router router,
    required _Handoff handoff,
    required IntentClassifier classifier,
    SmartRouteConfirm confirm = SmartRouteConfirm.auto,
    String todoist = '',
    String text = 'Look into how other apps do offline sync',
  }) async {
    final RecordingsController c = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'r1', projectId: 'p1', transcript: text),
      ],
      captureRouter: router,
      agentHandoff: handoff,
    );
    c.intentClassifier = classifier;
    c.smartRouteConfirm = confirm;
    c.todoistAgentCommand = todoist;
    return c;
  }

  test('a note goes through route() and closes the capture', () async {
    final _Router router = _Router();
    final RecordingsController c = await build(
      router: router,
      handoff: _Handoff(),
      classifier: _Classifier(SmartIntent.note),
    );
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.delivered, isTrue);
    expect(outcome.decision.intent, SmartIntent.note);
    expect(router.routed, 1);
    expect(c.recordings.single.isProcessedByUser, isTrue);
    expect(c.recordings.single.routes.single.kind, RouteKind.file);
  });

  test('an agent intent launches detached with the fixed directive', () async {
    final _Handoff handoff = _Handoff();
    final RecordingsController c = await build(
      router: _Router(),
      handoff: handoff,
      classifier: _Classifier(SmartIntent.verify),
    );
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.delivered, isTrue);
    final AgentHandoffRequest request = handoff.requests.single;
    expect(request.detached, isTrue);
    expect(request.directive, SmartIntent.verify.directive);
    expect(request.purpose, 'Verification');
    expect(request.honorSkipPermissions, isFalse);
    expect(request.command, isNull);
    expect(c.recordings.single.routes.single.kind, RouteKind.agent);
    expect(c.recordings.single.isProcessedByUser, isTrue);
  });

  test('the todoist intent launches the configured command', () async {
    final _Handoff handoff = _Handoff();
    final RecordingsController c = await build(
      router: _Router(),
      handoff: handoff,
      classifier: _Classifier(SmartIntent.todoist),
      todoist: 'claude --mcp-config /t.json',
    );
    await c.smartRoute('r1');
    final AgentHandoffRequest request = handoff.requests.single;
    expect(request.command!.executable, 'claude');
    expect(request.command!.arguments, <String>['--mcp-config', '/t.json']);
    expect(request.directive, SmartIntent.todoist.directive);
  });

  test('without a todoist command it is never offered nor launched', () async {
    final _Classifier classifier = _Classifier(SmartIntent.todoist);
    final _Router router = _Router();
    final RecordingsController c = await build(
      router: router,
      handoff: _Handoff(),
      classifier: classifier,
    );
    expect(classifier.lastOffered, isNull);
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(classifier.lastOffered, isNot(contains(SmartIntent.todoist)));
    // A model that names it anyway is demoted to a note by the offered set in
    // the real classifier; this fake ignores it, so the controller must too.
    expect(outcome!.decision.intent, SmartIntent.note);
    expect(router.routed, 1);
  });

  test('a command with a problem leaves todoist unavailable', () async {
    final RecordingsController c = await build(
      router: _Router(),
      handoff: _Handoff(),
      classifier: _Classifier(SmartIntent.note),
      todoist: 'claude --dangerously-skip-permissions',
    );
    expect(
      c.offeredSmartIntents(c.recordings.single),
      isNot(contains(SmartIntent.todoist)),
    );
    expect(c.todoistCommandProblem, isNotNull);
  });

  test('confirmEffects stops an effectful intent and delivers on confirm', () async {
    final _Handoff handoff = _Handoff();
    final RecordingsController c = await build(
      router: _Router(),
      handoff: handoff,
      classifier: _Classifier(SmartIntent.analyze),
      confirm: SmartRouteConfirm.confirmEffects,
    );
    final SmartRouteOutcome? asked = await c.smartRoute('r1');
    expect(asked!.awaitingConfirmation, isTrue);
    expect(asked.delivered, isFalse);
    expect(handoff.requests, isEmpty);
    expect(c.recordings.single.routes, isEmpty);
    expect(c.recordings.single.isProcessedByUser, isFalse);

    final SmartRouteOutcome? done = await c.smartRoute(
      'r1',
      confirmed: SmartIntent.analyze,
    );
    expect(done!.delivered, isTrue);
    expect(handoff.requests, hasLength(1));
  });

  test('confirmEffects does not stop a plain note', () async {
    final _Router router = _Router();
    final RecordingsController c = await build(
      router: router,
      handoff: _Handoff(),
      classifier: _Classifier(SmartIntent.note),
      confirm: SmartRouteConfirm.confirmEffects,
    );
    expect((await c.smartRoute('r1'))!.delivered, isTrue);
    expect(router.routed, 1);
  });

  test('a confirmed intent that is no longer available is refused', () async {
    final _Handoff handoff = _Handoff();
    final RecordingsController c = await build(
      router: _Router(),
      handoff: handoff,
      classifier: _Classifier(SmartIntent.note),
    );
    final SmartRouteOutcome? outcome = await c.smartRoute(
      'r1',
      confirmed: SmartIntent.todoist,
    );
    expect(outcome!.delivered, isFalse);
    expect(handoff.requests, isEmpty);
    expect(c.error, isNotNull);
    expect(c.recordings.single.routes, isEmpty);
  });

  test('a failing classifier falls back to keywords', () async {
    final _Handoff handoff = _Handoff();
    final RecordingsController c = await build(
      router: _Router(),
      handoff: handoff,
      classifier: _Classifier(SmartIntent.note, fails: true),
      text: 'Search for the best offline sync libraries',
    );
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.decision.intent, SmartIntent.search);
    expect(outcome.decision.fromModel, isFalse);
    expect(handoff.requests.single.directive, SmartIntent.search.directive);
  });

  test('a failed delivery leaves the capture open with only error set', () async {
    final RecordingsController c = await build(
      router: _Router(),
      handoff: _Handoff(failure: 'repo missing'),
      classifier: _Classifier(SmartIntent.search),
    );
    final Recording before = c.recordings.single;
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.delivered, isFalse);
    expect(c.error, contains('repo missing'));
    final Recording after = c.recordings.single;
    expect(after.routes, isEmpty);
    expect(after.isProcessedByUser, isFalse);
    expect(after.status, before.status);
    expect(after.transcript, before.transcript);
  });

  test('a failed note route leaves the capture open too', () async {
    final RecordingsController c = await build(
      router: _Router(failure: 'disk full'),
      handoff: _Handoff(),
      classifier: _Classifier(SmartIntent.note),
    );
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.delivered, isFalse);
    expect(c.recordings.single.isProcessedByUser, isFalse);
    expect(c.error, contains('disk full'));
  });

  test('a note with no inbox says so instead of delivering', () async {
    final RecordingsController c = await build(
      router: _Router(available: false),
      handoff: _Handoff(),
      classifier: _Classifier(SmartIntent.note),
    );
    final SmartRouteOutcome? outcome = await c.smartRoute('r1');
    expect(outcome!.delivered, isFalse);
    expect(c.error, contains('project'));
    expect(c.recordings.single.routes, isEmpty);
  });

  group('canSmartRoute', () {
    test('is false when nothing can deliver', () async {
      final RecordingsController c = await build(
        router: _Router(available: false),
        handoff: _Handoff(agents: const <HandoffAgent>[]),
        classifier: _Classifier(SmartIntent.note),
      );
      expect(c.canSmartRoute(c.recordings.single), isFalse);
    });

    test('is false for a capture with no text of its own', () async {
      final RecordingsController c = await build(
        router: _Router(),
        handoff: _Handoff(),
        classifier: _Classifier(SmartIntent.note),
        text: '   ',
      );
      expect(c.canSmartRoute(c.recordings.single), isFalse);
    });

    test('is false once the capture is done', () async {
      final RecordingsController c = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            transcript: 'x',
            isProcessedByUser: true,
          ),
        ],
        captureRouter: _Router(),
      );
      expect(c.canSmartRoute(c.recordings.single), isFalse);
    });

    test('is true with only an inbox or only an agent', () async {
      final RecordingsController inboxOnly = await build(
        router: _Router(),
        handoff: _Handoff(agents: const <HandoffAgent>[]),
        classifier: _Classifier(SmartIntent.note),
      );
      expect(inboxOnly.canSmartRoute(inboxOnly.recordings.single), isTrue);
    });

    test('gemini alone cannot run in the background, so it offers no agent intent', () async {
      final RecordingsController c = await build(
        router: _Router(available: false),
        handoff: _Handoff(
          agents: const <HandoffAgent>[
            HandoffAgent(id: 'geminiCli', label: 'Gemini', isDefault: true),
          ],
        ),
        classifier: _Classifier(SmartIntent.note),
      );
      expect(c.canSmartRoute(c.recordings.single), isFalse);
    });

    test('the project default is used unless it is gemini', () async {
      final _Handoff handoff = _Handoff(
        agents: const <HandoffAgent>[
          HandoffAgent(id: 'geminiCli', label: 'Gemini', isDefault: true),
          HandoffAgent(id: 'codex', label: 'Codex', isDefault: false),
          HandoffAgent(id: 'claudeCode', label: 'Claude Code', isDefault: false),
        ],
      );
      final RecordingsController c = await build(
        router: _Router(),
        handoff: handoff,
        classifier: _Classifier(SmartIntent.analyze),
      );
      await c.smartRoute('r1');
      expect(handoff.requests.single.agentId, 'claudeCode');
    });
  });
}

import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Resolves whatever the test says and records what it was asked to deliver.
class _Router implements CaptureRouter {
  _Router(this.kind);
  RouteKind? kind;
  final List<String> routed = <String>[];

  @override
  bool canRoute(String? projectId) => kind != null;

  @override
  RouteKind? resolvedKind(RoutedCapture capture) => kind;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    routed.add(capture.id);
    return RouteRecord(
      at: DateTime.utc(2026, 10, 8),
      kind: kind!,
      target: 'inbox.md',
    );
  }
}

class _Agents implements AgentHandoff {
  _Agents({this.available = true});
  bool available;
  final List<AgentHandoffRequest> launched = <AgentHandoffRequest>[];

  @override
  List<HandoffAgent> agentsFor(String? projectId) => available
      ? const <HandoffAgent>[
          HandoffAgent(id: 'claude', label: 'Claude Code', isDefault: true),
        ]
      : const <HandoffAgent>[];

  @override
  String taskPathFor(String captureId) => '.agent-tasks/$captureId.md';

  @override
  String promptFor(RoutedCapture capture) => capture.body;

  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async {
    launched.add(request);
    throw StateError('a suggestion must never launch directly');
  }
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('suggest_ui_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  const String reason = 'An agent should plan this';

  Future<
    ({
      RecordingsController controller,
      _Router router,
      _Agents agents,
      ValueNotifier<int> tick,
    })
  >
  pump(
    WidgetTester tester, {
    SuggestedRoute? suggestion = const SuggestedRoute(
      kind: SuggestedRouteKind.command,
      reason: reason,
    ),
    RouteKind? kind = RouteKind.command,
    bool agent = true,
  }) async {
    final _Router router = _Router(kind);
    final _Agents agents = _Agents(available: agent);
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'r1',
          title: 'Wire the thing',
          transcript: 'Wire the thing up.',
          projectId: 'p1',
          suggestedRoute: suggestion,
        ),
      ],
      captureRouter: router,
      agentHandoff: agents,
    );
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller),
        listenable: Listenable.merge(<Listenable>[controller, tick]),
      ),
    );
    await tester.pump();
    return (controller: controller, router: router, agents: agents, tick: tick);
  }

  Finder chip(String label) => find.textContaining(label);

  testWidgets('a valid suggestion shows one action, reason as tooltip', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(chip('SEND TO COMMAND'), findsOneWidget);
    expect(find.byTooltip(reason), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('each kind is labelled with what the tap will do', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      suggestion: const SuggestedRoute(kind: SuggestedRouteKind.file),
      kind: RouteKind.file,
    );
    expect(chip('SEND TO INBOX'), findsOneWidget);
  });

  testWidgets('an agent suggestion names the agent', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      suggestion: const SuggestedRoute(kind: SuggestedRouteKind.agent),
    );
    expect(chip('HAND OFF TO CLAUDE CODE'), findsOneWidget);
  });

  testWidgets('none, and a dismissed suggestion, draw nothing', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      suggestion: const SuggestedRoute(kind: SuggestedRouteKind.none),
    );
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.textContaining('SEND TO'), findsNothing);
  });

  testWidgets('a dismissed suggestion draws nothing', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      suggestion: const SuggestedRoute(
        kind: SuggestedRouteKind.command,
        auto: false,
      ),
    );
    expect(find.textContaining('SEND TO'), findsNothing);
  });

  testWidgets('the action disappears when its destination goes away', (
    WidgetTester tester,
  ) async {
    final h = await pump(tester);
    expect(chip('SEND TO COMMAND'), findsOneWidget);

    // Command unbound: the row still says `command`, but route() would now do
    // something else, so the control must not be drawn.
    h.router.kind = RouteKind.file;
    h.tick.value++;
    await tester.pump();
    expect(find.textContaining('SEND TO'), findsNothing);

    h.router.kind = null;
    h.tick.value++;
    await tester.pump();
    expect(find.textContaining('SEND TO'), findsNothing);
  });

  testWidgets('an agent action disappears when the agent does', (
    WidgetTester tester,
  ) async {
    final h = await pump(
      tester,
      suggestion: const SuggestedRoute(kind: SuggestedRouteKind.agent),
    );
    expect(find.textContaining('HAND OFF TO'), findsOneWidget);
    h.agents.available = false;
    h.tick.value++;
    await tester.pump();
    expect(find.textContaining('HAND OFF TO'), findsNothing);
  });

  testWidgets('tapping a route kind calls the existing route entry point', (
    WidgetTester tester,
  ) async {
    final h = await pump(tester);

    await tester.tap(chip('SEND TO COMMAND'));
    await tester.pump();
    await tester.pump();

    expect(h.router.routed, <String>['r1']);
    final Recording item = h.controller.recordings.single;
    expect(item.routes, hasLength(1));
    expect(item.isProcessedByUser, isTrue);
    // Routed: the suggestion has done its job and the card stops offering it.
    expect(find.textContaining('SEND TO'), findsNothing);
  });

  testWidgets('tapping agent opens the handoff sheet and does not launch', (
    WidgetTester tester,
  ) async {
    final h = await pump(
      tester,
      suggestion: const SuggestedRoute(kind: SuggestedRouteKind.agent),
    );

    await tester.tap(find.textContaining('HAND OFF TO'));
    await tester.pumpAndSettle();

    expect(find.text('LAUNCH SESSION'), findsOneWidget);
    expect(h.agents.launched, isEmpty);
    expect(h.controller.recordings.single.routes, isEmpty);
    expect(h.controller.recordings.single.isProcessedByUser, isFalse);
  });

  testWidgets('dismiss hides the action and persists the dismissal', (
    WidgetTester tester,
  ) async {
    final h = await pump(tester);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('SEND TO'), findsNothing);
    final SuggestedRoute stored =
        h.controller.recordings.single.suggestedRoute!;
    expect(stored.auto, isFalse);
    expect(stored.kind, SuggestedRouteKind.command);
    expect(h.controller.recordings.single.routes, isEmpty);
  });

  testWidgets('the dismiss control names itself and has a real hit area', (
    WidgetTester tester,
  ) async {
    await pump(tester);

    expect(
      find.byTooltip(RecordingCard.dismissSuggestionLabel),
      findsOneWidget,
    );
    final Size target = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.close_rounded),
        matching: find.byType(InkWell),
      ),
    );
    expect(target.width, greaterThanOrEqualTo(32));
    expect(target.height, greaterThanOrEqualTo(32));
  });
}

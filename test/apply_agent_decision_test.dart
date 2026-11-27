import 'dart:io';

import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_decision.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/agent_decision_support.dart';

/// `RecordingsController.applyAgentDecision(AgentDecision)` is created by #474:
/// `Future<DecisionOutcome> applyAgentDecision(AgentDecision d)`. It returns
/// `applied` only after a persist that landed, and THROWS (never returns) when
/// it cannot be sure: not initialized, unreadable index, repository write
/// failure. The drainer keeps the file on a throw.
void main() {
  late Directory dir;
  late SwitchableRepository repo;
  late ScriptedRouter router;
  late CollectingLog log;
  late CollectingClosureLog closures;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('apply_decision_');
    seedDirectory = dir;
    router = ScriptedRouter();
    log = CollectingLog();
    closures = CollectingClosureLog();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<RecordingsController> controllerWith(List<Recording> seed) async {
    repo = SwitchableRepository(dir, seed: seed);
    return buildController(repo, router: router, log: log, closures: closures);
  }

  AgentDecision decide(
    RecordingsController c,
    String id,
    AgentDecisionAction action, {
    String decisionId = decisionUuid,
  }) => makeDecision(
    id,
    version: versionOf(c, id),
    action: action,
    decisionId: decisionId,
  );

  test(
    'done closes with an external route, agent decision and closure',
    () async {
      // AC-5
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1'),
      ]);

      final DecisionOutcome o = await c.applyAgentDecision(
        decide(c, 'r1', AgentDecisionAction.done),
      );

      expectKind(o, DecisionOutcomeKind.applied);
      final Recording r = byId(c, 'r1');
      expect(r.isProcessedByUser, isTrue);
      expect(r.processedAt, isNotNull);
      expect(r.routes, hasLength(1));
      final RouteRecord route = r.routes.single;
      expect(route.kind.name, 'external');
      expect(route.target, 'codex');
      final Map<String, dynamic> decision =
          route.toJson()['decision'] as Map<String, dynamic>;
      expect(decision['decidedBy'], 'agent:codex');
      expect(decision['did'], 'opened PR #12');
      expect(decision['reason'], 'F2: handled it');
      expect(decision['decisionId'], decisionUuid);
      expect(decision['ruleId'], 'agent');
      expect(closures.appended, hasLength(1));
      expect(closures.appended.single.kind.name, 'agent');
      expect(closures.appended.single.recordingId, 'r1');
      expect(router.calls, 0, reason: 'done never delivers anything');
      // Persisted, not just in memory.
      expect(repo.saved.single.isProcessedByUser, isTrue);
      expect(repo.saved.single.routes, hasLength(1));
    },
  );

  test('done never borrows the suggestion rule id', () async {
    // AC-5 (gate: attribution)
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1').copyWith(
        suggestedRoute: const SuggestedRoute(
          kind: SuggestedRouteKind.file,
          reason: 'bound',
          ruleId: 'R10',
        ),
      ),
    ]);
    await c.applyAgentDecision(decide(c, 'r1', AgentDecisionAction.done));
    final Map<String, dynamic> decision =
        byId(c, 'r1').routes.single.toJson()['decision']
            as Map<String, dynamic>;
    expect(decision['ruleId'], 'agent');
  });

  test('route_file delivers, closes as a route and carries the rule when the '
      'suggestion matched', () async {
    // AC-5 (gate: attribution)
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1').copyWith(
        suggestedRoute: const SuggestedRoute(
          kind: SuggestedRouteKind.file,
          reason: 'inbox',
          ruleId: 'R10',
        ),
      ),
    ]);

    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.routeFile),
    );

    expectKind(o, DecisionOutcomeKind.applied);
    expect(router.calls, 1);
    final Recording r = byId(c, 'r1');
    expect(r.isProcessedByUser, isTrue);
    expect(r.routes.single.kind, RouteKind.file);
    final Map<String, dynamic> decision =
        r.routes.single.toJson()['decision'] as Map<String, dynamic>;
    expect(decision['ruleId'], 'R10');
    expect(decision['decidedBy'], 'agent:codex');
    expect(decision['decisionId'], decisionUuid);
    expect(decision['reason'], 'F2: handled it');
    expect(closures.appended.single.kind, ClosureKind.route);
  });

  test('route_command goes through the router and closes as a route', () async {
    // AC-5
    router.kind = RouteKind.command;
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.routeCommand),
    );
    expectKind(o, DecisionOutcomeKind.applied);
    expect(byId(c, 'r1').routes.single.kind, RouteKind.command);
    expect(closures.appended.single.kind, ClosureKind.route);
  });

  test('attribution is "agent" unless the suggestion is auto, has a rule and '
      'names the delivered kind', () async {
    // AC-5 (gate: attribution)
    final Map<String, SuggestedRoute?> cases = <String, SuggestedRoute?>{
      'other kind': const SuggestedRoute(
        kind: SuggestedRouteKind.command,
        ruleId: 'R20',
      ),
      'dismissed': const SuggestedRoute(
        kind: SuggestedRouteKind.file,
        ruleId: 'R10',
        auto: false,
      ),
      'no rule': const SuggestedRoute(kind: SuggestedRouteKind.file),
      'none': null,
    };
    for (final MapEntry<String, SuggestedRoute?> e in cases.entries) {
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1').copyWith(suggestedRoute: e.value),
      ]);
      await c.applyAgentDecision(
        decide(c, 'r1', AgentDecisionAction.routeFile),
      );
      final Map<String, dynamic> decision =
          byId(c, 'r1').routes.single.toJson()['decision']
              as Map<String, dynamic>;
      expect(decision['ruleId'], 'agent', reason: e.key);
      expect(decision['decidedBy'], 'agent:codex', reason: e.key);
    }
  });

  test('the same decision applied twice leaves one route record', () async {
    // AC-5
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final AgentDecision d = decide(c, 'r1', AgentDecisionAction.routeFile);

    expectKind(await c.applyAgentDecision(d), DecisionOutcomeKind.applied);
    expectKind(
      await c.applyAgentDecision(d),
      DecisionOutcomeKind.alreadyClosed,
    );

    expect(byId(c, 'r1').routes, hasLength(1));
    expect(router.calls, 1);
    expect(closures.appended, hasLength(1));
  });

  test('replay after the user reopened the capture changes nothing', () async {
    // AC-5, AC-6
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final AgentDecision d = decide(c, 'r1', AgentDecisionAction.done);
    await c.applyAgentDecision(d);
    await c.toggleProcessed('r1'); // reopen by hand
    expect(byId(c, 'r1').isProcessedByUser, isFalse);

    expectKind(
      await c.applyAgentDecision(d),
      DecisionOutcomeKind.alreadyClosed,
    );

    expect(byId(c, 'r1').routes, hasLength(1));
    expect(byId(c, 'r1').isProcessedByUser, isFalse);
  });

  test('a closed capture is alreadyClosed and untouched', () async {
    // AC-5
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1', processed: true),
    ]);
    final int saves = repo.saveCalls;
    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.done),
    );
    expectKind(o, DecisionOutcomeKind.alreadyClosed);
    expect(byId(c, 'r1').routes, isEmpty);
    expect(repo.saveCalls, saves);
  });

  test('a stale version is rejected and the capture stays open', () async {
    // AC-5
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final int saves = repo.saveCalls;
    final AgentDecision d = makeDecision(
      'r1',
      version: 'not-the-current-version',
      action: AgentDecisionAction.routeFile,
    );

    final DecisionOutcome o = await c.applyAgentDecision(d);

    expectKind(o, DecisionOutcomeKind.rejected, why: 'stale version');
    expect(byId(c, 'r1').isProcessedByUser, isFalse);
    expect(byId(c, 'r1').routes, isEmpty);
    expect(router.calls, 0, reason: 'checked before any delivery');
    expect(repo.saveCalls, saves);
  });

  test('an edit after the agent read the capture makes it stale', () async {
    // AC-5
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final AgentDecision d = decide(c, 'r1', AgentDecisionAction.done);
    await c.setTags('r1', const <String>['edited']);
    expectKind(
      await c.applyAgentDecision(d),
      DecisionOutcomeKind.rejected,
      why: 'stale version',
    );
    expect(byId(c, 'r1').isProcessedByUser, isFalse);
  });

  test('a missing capture is rejected', () async {
    // AC-5
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final DecisionOutcome o = await c.applyAgentDecision(
      makeDecision('ghost', version: 'v'),
    );
    expectKind(o, DecisionOutcomeKind.rejected, why: 'not found');
  });

  test('a failing route_file is rejected, leaves the capture open and sets no '
      'controller error', () async {
    // AC-5
    router.fail = true;
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);

    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.routeFile),
    );

    expectKind(o, DecisionOutcomeKind.rejected);
    expect(o.reason, isNotEmpty);
    expect(router.calls, 1);
    expect(byId(c, 'r1').isProcessedByUser, isFalse);
    expect(byId(c, 'r1').routes, isEmpty);
    expect(c.error, isNull, reason: 'the user did not press anything');
    expect(closures.appended, isEmpty);
  });

  test('route_command on a file-bound project is "kind unavailable"', () async {
    // AC-5
    router.kind = RouteKind.file;
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.routeCommand),
    );
    expectKind(o, DecisionOutcomeKind.rejected, why: 'kind unavailable');
    expect(router.calls, 0);
    expect(byId(c, 'r1').routes, isEmpty);
  });

  test('route_file on a Command-bound project is "kind unavailable"', () async {
    // AC-5
    router.kind = RouteKind.command;
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final DecisionOutcome o = await c.applyAgentDecision(
      decide(c, 'r1', AgentDecisionAction.routeFile),
    );
    expectKind(o, DecisionOutcomeKind.rejected, why: 'kind unavailable');
    expect(router.calls, 0);
  });

  test(
    'a capture deleted during delivery is rejected, not resurrected',
    () async {
      // AC-5 (gate: delivery race)
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1'),
      ]);
      router.during = () => c.deleteRecording('r1');

      final DecisionOutcome o = await c.applyAgentDecision(
        decide(c, 'r1', AgentDecisionAction.routeFile),
      );

      expectKind(
        o,
        DecisionOutcomeKind.rejected,
        why: 'deleted during delivery',
      );
      expect(c.recordings, isEmpty);
      expect(repo.saved, isEmpty);
      expect(
        log.mentions('deleted during delivery'),
        isTrue,
        reason: 'logged, because the delivery really happened',
      );
    },
  );

  test(
    'skip logs, persists nothing and leaves the row byte for byte',
    () async {
      // AC-5 (gate: skip)
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1'),
      ]);
      final int saves = repo.saveCalls;
      final Map<String, dynamic> before = byId(c, 'r1').toJson();

      final DecisionOutcome o = await c.applyAgentDecision(
        makeDecision(
          'r1',
          version: versionOf(c, 'r1'),
          action: AgentDecisionAction.skip,
          reason: 'needs the user',
        ),
      );

      expect(
        o.kind,
        isNot(DecisionOutcomeKind.rejected),
        reason: '${o.reason}',
      );
      expect(repo.saveCalls, saves, reason: 'the index is untouched');
      expect(byId(c, 'r1').toJson(), before);
      expect(byId(c, 'r1').isProcessedByUser, isFalse);
      expect(log.mentions('agent skipped'), isTrue);
      expect(log.mentions('needs the user'), isTrue);
    },
  );

  test('a capture scheduled for later is rejected for every action', () async {
    // AC-3 (gate: scheduled)
    final DateTime later = DateTime.now().add(const Duration(days: 3));
    for (final AgentDecisionAction action in <AgentDecisionAction>[
      AgentDecisionAction.done,
      AgentDecisionAction.routeFile,
    ]) {
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1', resurfaceAt: later),
      ]);
      final int saves = repo.saveCalls;
      final DecisionOutcome o = await c.applyAgentDecision(
        decide(c, 'r1', action),
      );
      expectKind(o, DecisionOutcomeKind.rejected);
      expect(byId(c, 'r1').isProcessedByUser, isFalse, reason: '$action');
      expect(byId(c, 'r1').routes, isEmpty, reason: '$action');
      expect(repo.saveCalls, saves, reason: '$action');
    }
    expect(router.calls, 0);
  });

  test('done on a repeating capture completes the occurrence, not the '
      'series', () async {
    // AC-5 (gate: repeating)
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording(
        'r1',
        repeatEveryDays: 7,
        resurfaceAt: DateTime.now().subtract(const Duration(hours: 1)),
      ),
    ]);
    final AgentDecision d = decide(c, 'r1', AgentDecisionAction.done);

    expectKind(await c.applyAgentDecision(d), DecisionOutcomeKind.applied);

    final Recording r = byId(c, 'r1');
    expect(r.isProcessedByUser, isFalse, reason: 'stays open for the next run');
    expect(
      r.resurfaceAt!.isAfter(DateTime.now().add(const Duration(days: 6))),
      isTrue,
    );
    expect(r.routes, hasLength(1));
    expect(r.routes.single.kind.name, 'external');
    expect(
      (r.routes.single.toJson()['decision'] as Map)['decidedBy'],
      'agent:codex',
    );
    expect(closures.appended, hasLength(1));
    // Replay is still one occurrence, not two.
    expectKind(
      await c.applyAgentDecision(d),
      DecisionOutcomeKind.alreadyClosed,
    );
    expect(byId(c, 'r1').routes, hasLength(1));
    expect(closures.appended, hasLength(1));
  });

  test('an unreadable index makes apply throw and writes nothing', () async {
    // AC-6 (gate: durability)
    final _UnreadableRepository bad = _UnreadableRepository(dir);
    final RecordingsController c = await buildController(
      bad,
      router: router,
      log: log,
      closures: closures,
    );
    expect(c.isIndexUnreadable, isTrue);
    await expectLater(
      c.applyAgentDecision(makeDecision('r1', version: 'v')),
      throwsA(anything),
    );
    expect(bad.saveCalls, 0);
  });

  test('a controller that never initialized makes apply throw', () async {
    // AC-6 (gate: durability)
    final RecordingsController c = await buildController(
      SwitchableRepository(dir, seed: <Recording>[seedRecording('r1')]),
      router: router,
      initialize: false,
    );
    expect(c.isInitialized, isFalse);
    await expectLater(
      c.applyAgentDecision(makeDecision('r1', version: 'v')),
      throwsA(anything),
    );
  });

  test('a repository write that throws makes apply throw and leaves the '
      'capture open', () async {
    // AC-6 (gate: durability)
    final RecordingsController c = await controllerWith(<Recording>[
      seedRecording('r1'),
    ]);
    final AgentDecision d = decide(c, 'r1', AgentDecisionAction.done);
    repo.failWrites = true;

    await expectLater(c.applyAgentDecision(d), throwsA(anything));

    expect(byId(c, 'r1').isProcessedByUser, isFalse);
    expect(byId(c, 'r1').routes, isEmpty);
    expect(closures.appended, isEmpty);

    // The failure was transient: the same file applies on the next pass.
    repo.failWrites = false;
    expectKind(await c.applyAgentDecision(d), DecisionOutcomeKind.applied);
    expect(byId(c, 'r1').routes, hasLength(1));
  });

  test(
    'route() keeps its contract: it still sets error on a failed delivery',
    () async {
      // AC-8 (regression guard for the _deliverAndClose extraction)
      router.fail = true;
      final RecordingsController c = await controllerWith(<Recording>[
        seedRecording('r1'),
      ]);
      await c.route('r1');
      expect(c.error, contains('repo is gone'));
      expect(byId(c, 'r1').routes, isEmpty);
      expect(log.entries.any((e) => e.level == LogLevel.error), isTrue);
    },
  );
}

class _UnreadableRepository extends SwitchableRepository {
  _UnreadableRepository(super.directory);

  @override
  Future<List<Recording>> loadAll() async =>
      throw const IndexUnreadableException('recordings.json', 'torn');
}

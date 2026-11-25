import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/switchboard/domain/capture_facts.dart';
import 'package:augustyniak_capture/features/switchboard/domain/capture_policy.dart';
import 'package:augustyniak_capture/features/switchboard/domain/decision.dart';
import 'package:augustyniak_capture/features/switchboard/domain/decision_log.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

class _Repo extends RecordingsRepository {
  _Repo(this._dir);
  final Directory _dir;
  List<Recording> saved = <Recording>[];
  int saves = 0;
  bool failSaves = false;

  @override
  Future<Directory> recordingsDirectory() async => _dir;

  @override
  Future<File> createSourceFile(String id, String extension) async {
    final File file = File(p.join(_dir.path, '$id.$extension'));
    await file.writeAsString('audio');
    return file;
  }

  @override
  Future<List<Recording>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    if (failSaves) throw const FileSystemException('disk full');
    saves++;
    saved = List<Recording>.from(recordings);
  }
}

class _Echo implements Processor {
  const _Echo();
  @override
  Future<String> process(CaptureSegment segment) async =>
      File(segment.filePath).readAsString();
}

class _Enrichment implements EnrichmentService {
  _Enrichment(this.result);
  EnrichmentResult result;
  Completer<void>? gate;
  Completer<void> started = Completer<void>();
  EnrichmentContext? lastContext;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    lastContext = context;
    if (!started.isCompleted) started.complete();
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    return result;
  }
}

class _Source implements EnrichmentContextSource {
  _Source(this.context);
  final EnrichmentContext context;
  final List<String?> requestedFor = <String?>[];

  @override
  Future<EnrichmentContext> contextFor(String? projectId) async {
    requestedFor.add(projectId);
    return context;
  }
}

class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<String?> stop() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

final Map<String, Project> _projects = <String, Project>{
  'a': const Project(id: 'a', name: 'Alpha', repoPath: '/nowhere'),
  'b': const Project(id: 'b', name: 'Beta', repoPath: '/nowhere'),
};

/// A router whose resolved kind is whatever the test says, so the controller's
/// "what would route() really do" question can be answered per project.
class _Router implements CaptureRouter {
  _Router(this.kinds);
  Map<String?, RouteKind?> kinds;
  @override
  bool canRoute(String? projectId) => kinds[projectId] != null;
  @override
  RouteKind? resolvedKind(RoutedCapture capture) => kinds[capture.projectId];
  @override
  Future<RouteRecord> route(RoutedCapture capture) async => RouteRecord(
    at: DateTime.utc(2026, 11, 23),
    kind: kinds[capture.projectId]!,
    target: 'target',
  );
}

class _Agents implements AgentHandoff {
  _Agents(this.projects);
  final Set<String?> projects;
  @override
  List<HandoffAgent> agentsFor(String? projectId) =>
      projects.contains(projectId)
      ? const <HandoffAgent>[
          HandoffAgent(id: 'claude', label: 'Claude Code', isDefault: true),
        ]
      : const <HandoffAgent>[];
  @override
  String taskPathFor(String captureId) => '';

  @override
  String? workspacePathFor(String captureId, String? projectId) => null;

  @override
  Future<void> attach(String sessionName) async {}
  @override
  String promptFor(RoutedCapture capture) => '';
  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async =>
      AgentHandoffResult(
        record: RouteRecord(
          at: DateTime.utc(2026, 11, 23),
          kind: RouteKind.agent,
          target: 'Claude Code',
          session: 'cap-rec-1-claude',
        ),
        taskPath: '.agent-tasks/rec-1.md',
        sessionName: 'cap-rec-1-claude',
        attachedToExistingSession: false,
      );
}

Recording _row({
  SuggestedRoute? suggestion,
  bool auto = false,
  bool noProject = false,
  String projectId = 'a',
}) => Recording(
  id: 'rec-1',
  filePath: '/tmp/rec-1.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1,
  status: RecordingStatus.completed,
  // A valid SHA-256 (fromJson drops anything else), so initialize()'s
  // content-hash backfill has nothing to write and the save-count assertions
  // measure the enrichment write alone.
  contentHash: 'a' * 64,
  projectId: noProject ? null : projectId,
  projectAuto: auto,
  suggestedRoute: suggestion,
);

class _Policy implements CapturePolicy {
  _Policy(this.answer);
  Decision? Function(CaptureFacts facts) answer;
  final List<CaptureFacts> seen = <CaptureFacts>[];

  @override
  Decision? decide(CaptureFacts facts) {
    seen.add(facts);
    return answer(facts);
  }
}

class _LoggedRow {
  _LoggedRow(this.captureId, this.decision, this.applied, this.skipReason);
  final String captureId;
  final Decision decision;
  final bool applied;
  final String? skipReason;
}

class _Log implements DecisionLog {
  _Log(this.repo);
  final _Repo repo;
  final List<_LoggedRow> rows = <_LoggedRow>[];
  final List<List<Recording>> savedAtAppend = <List<Recording>>[];
  bool throws = false;

  @override
  Future<void> append({
    required DateTime at,
    required String captureId,
    required Decision decision,
    required bool applied,
    String? skipReason,
  }) async {
    savedAtAppend.add(List<Recording>.of(repo.saved));
    if (throws) throw const FileSystemException('log unwritable');
    rows.add(_LoggedRow(captureId, decision, applied, skipReason));
  }
}

Decision _decision(
  String ruleId,
  SuggestedRouteKind kind, {
  String reason = 'because',
}) => Decision(
  ruleId: ruleId,
  kind: kind,
  reason: reason,
  facts: const CaptureFacts(
    category: CaptureCategory.agentTask,
    projectId: 'a',
    availableRouteKinds: <SuggestedRouteKind>[SuggestedRouteKind.command],
    modelRoute: null,
  ),
);

RouteRecord _record(RouteKind kind) =>
    RouteRecord(at: DateTime.utc(2026, 9, 21), kind: kind, target: 'x');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  late Directory dir;
  late _Repo repo;
  late File note;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('switchboard_controller');
    repo = _Repo(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<RecordingsController> seeded(
    Recording row, {
    EnrichmentResult result = const EnrichmentResult(
      title: 'Titled',
      category: CaptureCategory.agentTask,
    ),
    CapturePolicy? policy,
    DecisionLog? log,
    bool omitPolicy = false,
    _Router? router,
    _Enrichment? enrichment,
  }) async {
    note = File(p.join(dir.path, 'rec-1.txt'))..writeAsStringSync('hello');
    repo.saved = <Recording>[
      Recording.fromJson(<String, dynamic>{
        ...row.toJson(),
        'type': CaptureType.text.name,
        'transcript': 'hello',
        'filePath': note.path,
      }),
    ];
    final RecordingsController c = RecordingsController(
      repository: repo,
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _GrantingRecorder(),
      player: _FakePlayer(),
      enrichmentService: enrichment ?? _Enrichment(result),
      enrichmentContextSource: _Source(EnrichmentContext.none),
      projectById: (String id) => _projects[id],
      captureRouter:
          router ??
          _Router(<String?, RouteKind?>{
            'a': RouteKind.command,
            'b': RouteKind.file,
          }),
      agentHandoff: _Agents(<String?>{'a'}),
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: const _Echo(),
      }),
      capturePolicy: omitPolicy
          ? const DisabledCapturePolicy()
          : (policy ?? const DisabledCapturePolicy()),
      decisionLog: log ?? const NoopDecisionLog(),
    );
    addTearDown(c.dispose);
    await c.initialize();
    return c;
  }

  Future<void> reEnrich(RecordingsController c) async {
    await c.retryEnrichment('rec-1');
    await c.waitForProcessing();
    while (c.isEnriching('rec-1')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('enrichment hook', () {
    test(
      'the decision lands with its ruleId in the same single saveAll',
      () async {
        final _Policy policy = _Policy(
          (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
        );
        final RecordingsController c = await seeded(_row(), policy: policy);
        final int before = repo.saves;

        await reEnrich(c);

        expect(repo.saves - before, 1);
        const SuggestedRoute expected = SuggestedRoute(
          kind: SuggestedRouteKind.command,
          reason: 'because',
          ruleId: 'R10',
        );
        expect(c.recordings.single.suggestedRoute, expected);
        // Persisted in that one write, together with the enrichment itself.
        expect(repo.saved.single.suggestedRoute, expected);
        expect(repo.saved.single.title, 'Titled');
        // The policy saw the item as enrichment left it.
        expect(policy.seen.single.category, CaptureCategory.agentTask);
        expect(policy.seen.single.projectId, 'a');
      },
    );

    test('the policy runs even when the model gave no route answer', () async {
      final _Policy policy = _Policy(
        (CaptureFacts f) => _decision('R20', SuggestedRouteKind.agent),
      );
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(category: CaptureCategory.agentTask),
        policy: policy,
      );
      await reEnrich(c);
      expect(policy.seen, hasLength(1));
      expect(policy.seen.single.modelRoute, isNull);
      expect(c.recordings.single.suggestedRoute!.ruleId, 'R20');
    });

    test('the policy receives the model\'s answered kind', () async {
      final _Policy policy = _Policy((CaptureFacts f) => null);
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(
          category: CaptureCategory.note,
          routeAnswered: true,
          routeKind: SuggestedRouteKind.none,
        ),
        policy: policy,
      );
      await reEnrich(c);
      expect(policy.seen.single.modelRoute, SuggestedRouteKind.none);
    });

    test(
      'a route kind the model answered but was not offered is withheld',
      () async {
        // Nothing is routable for 'n' when enrichment offers the routes, so
        // none are offered; the inbox becomes available while the model is
        // still answering, and the model names it anyway.
        final _Router router = _Router(<String?, RouteKind?>{});
        final _Enrichment enrichment = _Enrichment(
          const EnrichmentResult(
            category: CaptureCategory.note,
            routeAnswered: true,
            routeKind: SuggestedRouteKind.file,
          ),
        )..gate = Completer<void>();
        final _Policy policy = _Policy((CaptureFacts f) => null);
        final RecordingsController c = await seeded(
          _row(projectId: 'n'),
          policy: policy,
          router: router,
          enrichment: enrichment,
        );
        enrichment.started = Completer<void>();

        final Future<void> done = reEnrich(c);
        await enrichment.started.future;
        expect(enrichment.lastContext!.routeKinds, isEmpty);
        router.kinds['n'] = RouteKind.file;
        enrichment.gate!.complete();
        await done;

        expect(policy.seen.single.availableRouteKinds, <SuggestedRouteKind>[
          SuggestedRouteKind.file,
        ]);
        expect(policy.seen.single.modelRoute, isNull);
        expect(c.recordings.single.suggestedRoute, isNull);
      },
    );

    test(
      'a dismissed suggestion is never overwritten, but the row is logged',
      () async {
        const SuggestedRoute dismissed = SuggestedRoute(
          kind: SuggestedRouteKind.file,
          auto: false,
        );
        final _Log log = _Log(repo);
        final RecordingsController c = await seeded(
          _row(suggestion: dismissed),
          policy: _Policy(
            (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
          ),
          log: log,
        );
        await reEnrich(c);
        expect(c.recordings.single.suggestedRoute, dismissed);
        expect(log.rows.single.applied, isFalse);
        expect(log.rows.single.skipReason, 'dismissed');
        expect(log.rows.single.decision.ruleId, 'R10');
      },
    );

    test(
      'a row that already has routes is untouched and logged as routed',
      () async {
        final _Log log = _Log(repo);
        final RecordingsController c = await seeded(
          _row().copyWith(routes: <RouteRecord>[_record(RouteKind.file)]),
          policy: _Policy(
            (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
          ),
          log: log,
        );
        await reEnrich(c);
        expect(c.recordings.single.suggestedRoute, isNull);
        expect(log.rows.single.applied, isFalse);
        expect(log.rows.single.skipReason, 'routed');
      },
    );

    test('R90 leaves suggestedRoute unchanged and is logged only', () async {
      final _Log log = _Log(repo);
      final RecordingsController c = await seeded(
        _row(),
        policy: _Policy(
          (CaptureFacts f) => _decision('R90', SuggestedRouteKind.none),
        ),
        log: log,
      );
      await reEnrich(c);
      expect(c.recordings.single.suggestedRoute, isNull);
      expect(
        c.recordings.single.toJson().containsKey('suggestedRoute'),
        isFalse,
      );
      expect(log.rows.single.decision.ruleId, 'R90');
      expect(log.rows.single.applied, isFalse);
      expect(log.rows.single.skipReason, 'none');
    });

    test('R90 does not erase an earlier model suggestion', () async {
      const SuggestedRoute earlier = SuggestedRoute(
        kind: SuggestedRouteKind.agent,
        reason: 'earlier',
      );
      final RecordingsController c = await seeded(
        _row(suggestion: earlier),
        policy: _Policy(
          (CaptureFacts f) => _decision('R90', SuggestedRouteKind.none),
        ),
      );
      await reEnrich(c);
      expect(c.recordings.single.suggestedRoute, earlier);
    });

    test(
      'an applied decision is logged applied:true with no skipReason',
      () async {
        final _Log log = _Log(repo);
        final RecordingsController c = await seeded(
          _row(),
          policy: _Policy(
            (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
          ),
          log: log,
        );
        await reEnrich(c);
        expect(log.rows.single.captureId, 'rec-1');
        expect(log.rows.single.applied, isTrue);
        expect(log.rows.single.skipReason, isNull);
      },
    );

    test(
      'a throwing policy still persists the enrichment; status and source intact',
      () async {
        final RecordingsController c = await seeded(
          _row(),
          policy: _Policy((CaptureFacts f) => throw StateError('boom')),
        );
        final int before = repo.saves;
        await reEnrich(c);
        final Recording saved = repo.saved.single;
        expect(repo.saves - before, 1);
        expect(saved.title, 'Titled');
        expect(saved.category, CaptureCategory.agentTask);
        expect(saved.status, RecordingStatus.completed);
        expect(saved.suggestedRoute, isNull);
        expect(note.existsSync(), isTrue);
        expect(note.readAsStringSync(), 'hello');
      },
    );

    test('a throwing log is swallowed', () async {
      final _Log log = _Log(repo)..throws = true;
      final RecordingsController c = await seeded(
        _row(),
        policy: _Policy(
          (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
        ),
        log: log,
      );
      await reEnrich(c);
      expect(log.savedAtAppend, hasLength(1));
      expect(repo.saved.single.status, RecordingStatus.completed);
      expect(repo.saved.single.suggestedRoute!.ruleId, 'R10');
      expect(c.error, isNull);
    });

    test('the log is appended only after the persist', () async {
      final _Log log = _Log(repo);
      final RecordingsController c = await seeded(
        _row(),
        policy: _Policy(
          (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
        ),
        log: log,
      );
      await reEnrich(c);
      expect(log.savedAtAppend.single.single.suggestedRoute!.ruleId, 'R10');
    });

    test('nothing is appended when the persist did not happen', () async {
      final _Log log = _Log(repo);
      final RecordingsController c = await seeded(
        _row(),
        policy: _Policy(
          (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
        ),
        log: log,
      );
      repo.failSaves = true;
      await reEnrich(c);
      expect(log.rows, isEmpty);
      expect(log.savedAtAppend, isEmpty);
    });

    test('nothing is appended when the index was unreadable', () async {
      final _Log log = _Log(repo);
      final RecordingsController c = RecordingsController(
        repository: _UnreadableRepo(dir),
        transcriptionService: const DisabledTranscriptionService(),
        recorder: _GrantingRecorder(),
        player: _FakePlayer(),
        enrichmentService: _Enrichment(
          const EnrichmentResult(category: CaptureCategory.agentTask),
        ),
        capturePolicy: _Policy(
          (CaptureFacts f) => _decision('R10', SuggestedRouteKind.command),
        ),
        decisionLog: log,
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.retryEnrichment('rec-1');
      await c.waitForProcessing();
      expect(log.rows, isEmpty);
      expect(log.savedAtAppend, isEmpty);
    });

    test('with the default policy behaviour equals today', () async {
      final _Log log = _Log(repo);
      final RecordingsController c = await seeded(
        _row(),
        omitPolicy: true,
        log: log,
        result: const EnrichmentResult(
          category: CaptureCategory.agentTask,
          routeAnswered: true,
          routeKind: SuggestedRouteKind.command,
          routeReason: 'an agent should do this',
        ),
      );
      await reEnrich(c);
      // The model's own answer is stored exactly as before, with no ruleId
      // key, and the disabled policy logs nothing.
      expect(c.recordings.single.toJson()['suggestedRoute'], <String, dynamic>{
        'kind': 'command',
        'reason': 'an agent should do this',
        'auto': true,
      });
      expect(log.rows, isEmpty);
    });
  });

  group('stamping RouteRecord.decision', () {
    SuggestedRoute suggestion(
      SuggestedRouteKind kind, {
      String? ruleId = 'R10',
      bool auto = true,
    }) => SuggestedRoute.fromJson(<String, dynamic>{
      'kind': kind.name,
      'reason': 'why',
      'auto': auto,
      'ruleId': ?ruleId,
    })!;

    Future<Map<String, dynamic>?> routedDecision(SuggestedRoute s) async {
      final RecordingsController c = await seeded(_row(suggestion: s));
      await c.route('rec-1');
      expect(c.recordings.single.routes, hasLength(1));
      return c.recordings.single.routes.single.toJson()['decision']
          as Map<String, dynamic>?;
    }

    test(
      'route() stamps when the suggestion was automatic and the kinds match',
      () async {
        expect(
          await routedDecision(suggestion(SuggestedRouteKind.command)),
          <String, dynamic>{'ruleId': 'R10', 'reason': 'why'},
        );
      },
    );

    test('route() does not stamp when the kinds differ', () async {
      expect(await routedDecision(suggestion(SuggestedRouteKind.file)), isNull);
    });

    test('route() does not stamp a dismissed suggestion', () async {
      expect(
        await routedDecision(
          suggestion(SuggestedRouteKind.command, auto: false),
        ),
        isNull,
      );
    });

    test('route() does not stamp a suggestion without a ruleId', () async {
      expect(
        await routedDecision(
          suggestion(SuggestedRouteKind.command, ruleId: null),
        ),
        isNull,
      );
    });

    test('handoff() stamps on the accept path when the kinds match', () async {
      final RecordingsController c = await seeded(
        _row(suggestion: suggestion(SuggestedRouteKind.agent, ruleId: 'R20')),
      );
      await c.handoff('rec-1', agentId: 'claude');
      expect(
        c.recordings.single.routes.single.toJson()['decision'],
        <String, dynamic>{'ruleId': 'R20', 'reason': 'why'},
      );
    });

    test(
      'handoff() does not stamp when the suggestion was another kind',
      () async {
        final RecordingsController c = await seeded(
          _row(suggestion: suggestion(SuggestedRouteKind.command)),
        );
        await c.handoff('rec-1', agentId: 'claude');
        expect(
          c.recordings.single.routes.single.toJson().containsKey('decision'),
          isFalse,
        );
      },
    );
  });
}

class _UnreadableRepo extends RecordingsRepository {
  _UnreadableRepo(this._dir);
  final Directory _dir;

  @override
  Future<Directory> recordingsDirectory() async => _dir;

  @override
  Future<List<Recording>> loadAll() async =>
      throw const IndexUnreadableException('recordings.json', 'bad');

  @override
  Future<void> saveAll(List<Recording> recordings) async =>
      throw StateError('must not write');
}

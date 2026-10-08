import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_prompt.dart';
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
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

class _Repo extends RecordingsRepository {
  _Repo(this._dir);
  final Directory _dir;
  List<Recording> saved = <Recording>[];

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
  Future<RouteRecord> route(RoutedCapture capture) async =>
      throw UnimplementedError();
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
  String promptFor(RoutedCapture capture) => '';
  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async =>
      throw UnimplementedError();
}

const EnrichmentContext _withRoutes = EnrichmentContext(
  routeKinds: <SuggestedRouteKind>[SuggestedRouteKind.command],
);

Recording _row({SuggestedRoute? suggestion, bool auto = false}) => Recording(
  id: 'rec-1',
  filePath: '/tmp/rec-1.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1,
  status: RecordingStatus.completed,
  projectId: 'a',
  projectAuto: auto,
  suggestedRoute: suggestion,
);

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

  group('Recording.suggestedRoute', () {
    test('round-trips, and the key is absent while null', () {
      const SuggestedRoute s = SuggestedRoute(
        kind: SuggestedRouteKind.command,
        reason: 'needs an agent',
      );
      final Map<String, dynamic> json = _row(suggestion: s).toJson();
      expect(json['suggestedRoute'], <String, dynamic>{
        'kind': 'command',
        'reason': 'needs an agent',
        'auto': true,
      });
      expect(Recording.fromJson(json).suggestedRoute, s);
      expect(_row().toJson().containsKey('suggestedRoute'), isFalse);
    });

    test('an explicit none is kept, and differs from absent', () {
      const SuggestedRoute none = SuggestedRoute(kind: SuggestedRouteKind.none);
      final Recording back = Recording.fromJson(
        _row(suggestion: none).toJson(),
      );
      expect(back.suggestedRoute, none);
      expect(back.suggestedRoute, isNotNull);
    });

    test('legacy JSON loads unchanged; an unknown kind degrades to absent', () {
      final Map<String, dynamic> legacy = _row().toJson();
      final Recording loaded = Recording.fromJson(legacy);
      expect(loaded.suggestedRoute, isNull);
      expect(loaded.toJson(), legacy);

      for (final Object? junk in <Object?>[
        <String, dynamic>{'kind': 'teleport', 'auto': true},
        <String, dynamic>{'auto': true},
        'command',
        7,
      ]) {
        legacy['suggestedRoute'] = junk;
        expect(
          Recording.fromJson(legacy).suggestedRoute,
          isNull,
          reason: '$junk',
        );
      }
    });

    test('a missing auto flag reads as user-owned', () {
      final Map<String, dynamic> json = _row().toJson()
        ..['suggestedRoute'] = <String, dynamic>{'kind': 'file'};
      expect(Recording.fromJson(json).suggestedRoute!.auto, isFalse);
    });

    test('survives the sync codec, and stays out of the payload when null', () {
      const SuggestedRoute s = SuggestedRoute(
        kind: SuggestedRouteKind.file,
        reason: 'r',
        auto: false,
      );
      final Map<String, Object?> row = SyncRowCodec.recording(
        _row(suggestion: s),
      );
      expect(SyncRowCodec.recordingFromRow(row)!.suggestedRoute, s);
      final Map<String, Object?> plain = SyncRowCodec.recording(_row());
      expect(
        (plain['payload'] as Map<String, Object?>).containsKey(
          'suggestedRoute',
        ),
        isFalse,
      );
      expect(SyncRowCodec.recordingFromRow(plain)!.suggestedRoute, isNull);
    });
  });

  group('prompt', () {
    test('lists the offered kinds in their own fenced block, with none', () {
      final String prompt = buildEnrichmentSystemPrompt(
        context: const EnrichmentContext(
          routeKinds: <SuggestedRouteKind>[
            SuggestedRouteKind.command,
            SuggestedRouteKind.agent,
          ],
        ),
      );
      expect(prompt, contains('--- BEGIN ROUTE LIST ---'));
      expect(prompt, contains('- "command":'));
      expect(prompt, contains('- "agent":'));
      expect(prompt, contains('- "none":'));
      expect(prompt, isNot(contains('- "file":')));
      expect(prompt, contains('--- END ROUTE LIST ---'));
      expect(prompt, contains('- "route":'));
    });

    test('is unchanged when nothing is offered', () {
      final String prompt = buildEnrichmentSystemPrompt(
        context: const EnrichmentContext(profile: 'me'),
      );
      expect(prompt, isNot(contains('ROUTE LIST')));
      expect(prompt, isNot(contains('"route"')));
    });

    test('an offered kind alone makes the context non-empty', () {
      expect(_withRoutes.isEmpty, isFalse);
    });
  });

  group('parser', () {
    String body(String content) => jsonEncode(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'message': <String, dynamic>{'content': content},
        },
      ],
    });
    EnrichmentResult parse(String raw) =>
        HttpChatEnrichmentService.parseResponse(body(raw));

    test('a named kind with a reason is an answer', () {
      final EnrichmentResult r = parse(
        '{"route":{"kind":"command","reason":" plan this "}}',
      );
      expect(r.routeAnswered, isTrue);
      expect(r.routeKind, SuggestedRouteKind.command);
      expect(r.routeReason, 'plan this');
    });

    test('null and none are an answer: leave it on the desk', () {
      for (final String raw in <String>[
        '{"route":null}',
        '{"route":{"kind":"none"}}',
      ]) {
        final EnrichmentResult r = parse(raw);
        expect(r.routeAnswered, isTrue, reason: raw);
        expect(r.routeKind, SuggestedRouteKind.none, reason: raw);
      }
    });

    test('an absent key, or an unusable value, says nothing', () {
      for (final String raw in <String>[
        '{"title":"T"}',
        '{"route":7}',
        '{"route":"command"}',
        '{"route":{"kind":"teleport"}}',
        '{"route":{"reason":"x"}}',
        '{"route":{"kind":3}}',
      ]) {
        final EnrichmentResult r = parse(raw);
        expect(r.routeAnswered, isFalse, reason: raw);
        expect(r.routeKind, isNull, reason: raw);
      }
    });
  });

  group('controller', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('suggested_route'));
    tearDown(() => dir.deleteSync(recursive: true));

    RecordingsController build(
      _Repo repo, {
      required _Enrichment enrichment,
      required _Source source,
      CaptureRouter? router,
      AgentHandoff? agents,
    }) {
      final RecordingsController c = RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
        recorder: _GrantingRecorder(),
        player: _FakePlayer(),
        enrichmentService: enrichment,
        enrichmentContextSource: source,
        projectById: (String id) => _projects[id],
        captureRouter:
            router ??
            _Router(<String?, RouteKind?>{
              'a': RouteKind.command,
              'b': RouteKind.file,
            }),
        agentHandoff: agents ?? _Agents(<String?>{'a'}),
        processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
          CaptureType.text: const _Echo(),
        }),
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<RecordingsController> seeded(
      Recording row, {
      required EnrichmentResult result,
      _Source? source,
      CaptureRouter? router,
      AgentHandoff? agents,
      _Enrichment? enrichment,
    }) async {
      final _Repo repo = _Repo(dir);
      final File note = File(p.join(dir.path, 'rec-1.txt'))
        ..writeAsStringSync('hello');
      repo.saved = <Recording>[
        Recording.fromJson(<String, dynamic>{
          ...row.toJson(),
          'type': CaptureType.text.name,
          'transcript': 'hello',
          'filePath': note.path,
        }),
      ];
      final RecordingsController c = build(
        repo,
        enrichment: enrichment ?? _Enrichment(result),
        source: source ?? _Source(EnrichmentContext.none),
        router: router,
        agents: agents,
      );
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

    test('offers the kinds this item would really perform', () async {
      final _Source source = _Source(EnrichmentContext.none);
      final _Enrichment enrichment = _Enrichment(const EnrichmentResult());
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(),
        source: source,
        enrichment: enrichment,
      );
      await reEnrich(c);
      // Project 'a': Command resolved (never file as well) plus an agent.
      expect(enrichment.lastContext!.routeKinds, <SuggestedRouteKind>[
        SuggestedRouteKind.command,
        SuggestedRouteKind.agent,
      ]);
    });

    test('nothing is offered once the item has a route', () async {
      final _Enrichment enrichment = _Enrichment(const EnrichmentResult());
      final RecordingsController c = await seeded(
        _row().copyWith(
          routes: <RouteRecord>[
            RouteRecord(
              at: DateTime.utc(2026, 9, 21),
              kind: RouteKind.file,
              target: 'inbox.md',
            ),
          ],
        ),
        result: const EnrichmentResult(),
        enrichment: enrichment,
      );
      await reEnrich(c);
      expect(enrichment.lastContext!.routeKinds, isEmpty);
    });

    test('a valid kind is stored as a model-owned suggestion', () async {
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.command,
          routeReason: 'an agent should do this',
        ),
      );
      await reEnrich(c);
      expect(
        c.recordings.single.suggestedRoute,
        const SuggestedRoute(
          kind: SuggestedRouteKind.command,
          reason: 'an agent should do this',
        ),
      );
    });

    test('an explicit none is stored', () async {
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.none,
        ),
      );
      await reEnrich(c);
      expect(c.recordings.single.suggestedRoute!.kind, SuggestedRouteKind.none);
    });

    test('a kind that was not offered is dropped, storing nothing', () async {
      // `file` is not what route() would do for project 'a' (it is Command),
      // and 'b' has no agent.
      for (final SuggestedRouteKind kind in <SuggestedRouteKind>[
        SuggestedRouteKind.file,
      ]) {
        final RecordingsController c = await seeded(
          _row(),
          result: EnrichmentResult(routeAnswered: true, routeKind: kind),
        );
        await reEnrich(c);
        expect(c.recordings.single.suggestedRoute, isNull, reason: '$kind');
      }
    });

    test('an unavailable agent is dropped', () async {
      final RecordingsController c = await seeded(
        _row(),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.agent,
        ),
        agents: _Agents(<String?>{}),
      );
      await reEnrich(c);
      expect(c.recordings.single.suggestedRoute, isNull);
    });

    test('validated for the project that ends up on the item', () async {
      // An auto stamp on 'a' (Command + agent) that the model moves to 'b'
      // (inbox only): `command` was offered for 'a' but is wrong for 'b'.
      final RecordingsController dropped = await seeded(
        _row(auto: true),
        result: const EnrichmentResult(
          projectId: 'b',
          projectAnswered: true,
          routeAnswered: true,
          routeKind: SuggestedRouteKind.command,
        ),
        source: _Source(
          const EnrichmentContext(
            projects: <EnrichmentProjectOption>[
              EnrichmentProjectOption(id: 'a', name: 'Alpha'),
              EnrichmentProjectOption(id: 'b', name: 'Beta'),
            ],
          ),
        ),
      );
      await reEnrich(dropped);
      expect(dropped.recordings.single.projectId, 'b');
      expect(dropped.recordings.single.suggestedRoute, isNull);
    });

    test('a user dismissal survives re-enrichment', () async {
      final RecordingsController c = await seeded(
        _row(
          suggestion: const SuggestedRoute(
            kind: SuggestedRouteKind.command,
            auto: false,
          ),
        ),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.agent,
          routeReason: 'new idea',
        ),
      );
      await reEnrich(c);
      expect(
        c.recordings.single.suggestedRoute,
        const SuggestedRoute(kind: SuggestedRouteKind.command, auto: false),
      );
    });

    test('a model-written suggestion is replaced by a later run', () async {
      final RecordingsController c = await seeded(
        _row(suggestion: const SuggestedRoute(kind: SuggestedRouteKind.agent)),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.command,
        ),
      );
      await reEnrich(c);
      expect(
        c.recordings.single.suggestedRoute!.kind,
        SuggestedRouteKind.command,
      );
    });

    test('a silent reply leaves the existing suggestion alone', () async {
      final RecordingsController c = await seeded(
        _row(suggestion: const SuggestedRoute(kind: SuggestedRouteKind.agent)),
        result: const EnrichmentResult(),
      );
      await reEnrich(c);
      expect(
        c.recordings.single.suggestedRoute!.kind,
        SuggestedRouteKind.agent,
      );
    });

    test('a routed item gets no new suggestion', () async {
      final RecordingsController c = await seeded(
        _row().copyWith(
          routes: <RouteRecord>[
            RouteRecord(
              at: DateTime.utc(2026, 9, 21),
              kind: RouteKind.command,
              target: 'host',
            ),
          ],
        ),
        result: const EnrichmentResult(
          routeAnswered: true,
          routeKind: SuggestedRouteKind.command,
        ),
      );
      await reEnrich(c);
      expect(c.recordings.single.suggestedRoute, isNull);
    });

    test('dismissing keeps the suggestion but hands it to the user', () async {
      final RecordingsController c = await seeded(
        _row(
          suggestion: const SuggestedRoute(
            kind: SuggestedRouteKind.command,
            reason: 'r',
          ),
        ),
        result: const EnrichmentResult(),
      );
      await c.dismissSuggestedRoute('rec-1');
      expect(
        c.recordings.single.suggestedRoute,
        const SuggestedRoute(
          kind: SuggestedRouteKind.command,
          reason: 'r',
          auto: false,
        ),
      );
    });

    test(
      'the action is hidden for none, dismissed, routed or unavailable',
      () async {
        final _Router router = _Router(<String?, RouteKind?>{
          'a': RouteKind.command,
        });
        final RecordingsController c = await seeded(
          _row(
            suggestion: const SuggestedRoute(kind: SuggestedRouteKind.command),
          ),
          result: const EnrichmentResult(),
          router: router,
        );
        Recording item() => c.recordings.single;
        expect(
          c.suggestedRouteAction(item())?.kind,
          SuggestedRouteKind.command,
        );

        router.kinds = <String?, RouteKind?>{'a': RouteKind.file};
        expect(
          c.suggestedRouteAction(item()),
          isNull,
          reason: 'command unbound',
        );

        router.kinds = <String?, RouteKind?>{};
        expect(c.suggestedRouteAction(item()), isNull);

        Recording with_(SuggestedRoute s) => item().copyWith(suggestedRoute: s);
        router.kinds = <String?, RouteKind?>{'a': RouteKind.command};
        expect(
          c.suggestedRouteAction(
            with_(const SuggestedRoute(kind: SuggestedRouteKind.none)),
          ),
          isNull,
        );
        expect(
          c.suggestedRouteAction(
            with_(
              const SuggestedRoute(
                kind: SuggestedRouteKind.command,
                auto: false,
              ),
            ),
          ),
          isNull,
        );
        expect(
          c.suggestedRouteAction(
            item().copyWith(
              routes: <RouteRecord>[
                RouteRecord(
                  at: DateTime.utc(2026, 9, 21),
                  kind: RouteKind.command,
                  target: 'h',
                ),
              ],
            ),
          ),
          isNull,
        );
      },
    );
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/connections/data/file_triage_log.dart';
import 'package:augustyniak_capture/features/connections/data/http_daily_triage_service.dart';
import 'package:augustyniak_capture/features/connections/domain/daily_triage.dart';
import 'package:augustyniak_capture/features/connections/presentation/daily_triage_controller.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Recording capture(
  String id, {
  String? text = 'Some text',
  bool processed = false,
  CapturePriority? priority,
  DateTime? at,
}) => Recording(
  id: id,
  filePath: '/tmp/$id.txt',
  createdAt: at ?? DateTime(2026, 10, 1, 9),
  durationMs: 0,
  status: RecordingStatus.completed,
  type: CaptureType.text,
  transcript: text,
  isProcessedByUser: processed,
  priority: priority,
);

const ProviderProfile profile = ProviderProfile(
  id: 'p',
  name: 'Model',
  endpoint: 'https://example.com/v1/chat/completions',
  kind: ProfileKind.enrichment,
  model: 'test-model',
  bearerToken: 'token',
);

http.Response modelReply(Object content, {Map<String, int>? usage}) =>
    http.Response.bytes(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'usage': ?usage,
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content': content is String ? content : jsonEncode(content),
              },
            },
          ],
        }),
      ),
      200,
    );

/// In-memory log. Extends nothing that touches a disk, so the controller's
/// whole contract can be exercised without a binding.
class MemoryTriageLog implements TriageLog {
  final List<TriageDigest> digests = <TriageDigest>[];
  final List<TriageDecision> decisions = <TriageDecision>[];
  bool failLoad = false;

  @override
  Future<TriageHistory> load() async {
    if (failLoad) throw const FileSystemException('unreadable');
    return TriageHistory.fold(digests: digests, decisions: decisions);
  }

  @override
  Future<void> appendDigest(TriageDigest digest) async => digests.add(digest);

  @override
  Future<void> appendDecision(TriageDecision decision) async =>
      decisions.add(decision);
}

class RecordingActions implements TriageActions {
  final List<String> calls = <String>[];

  @override
  Future<void> close(String id) async => calls.add('close:$id');

  @override
  Future<void> setPriority(String id, CapturePriority priority) async =>
      calls.add('priority:$id:${priority.name}');
}

class ScriptedService implements DailyTriageService {
  ScriptedService(this.answer);

  Future<TriageDigest> Function(List<Recording>) answer;
  int calls = 0;

  @override
  Future<TriageDigest> triage(
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  }) {
    calls++;
    return answer(captures);
  }
}

void main() {
  group('domain', () {
    test('a proposal key ignores id order and carries the rerank target', () {
      const TriageProposal a = TriageProposal(
        kind: TriageKind.merge,
        reason: 'r',
        captureIds: <String>['b', 'a'],
      );
      const TriageProposal b = TriageProposal(
        kind: TriageKind.merge,
        reason: 'different wording',
        captureIds: <String>['a', 'b'],
      );
      expect(a.key, b.key);
      const TriageProposal up = TriageProposal(
        kind: TriageKind.rerank,
        reason: 'r',
        captureIds: <String>['a'],
        priority: CapturePriority.p0,
      );
      const TriageProposal down = TriageProposal(
        kind: TriageKind.rerank,
        reason: 'r',
        captureIds: <String>['a'],
        priority: CapturePriority.p3,
      );
      expect(up.key, isNot(down.key));
    });

    test('triage is due with no digest or one older than 24 hours', () {
      final DateTime now = DateTime(2026, 10, 3, 12);
      expect(triageIsDue(null, now), isTrue);
      expect(
        triageIsDue(now.subtract(const Duration(hours: 23)), now),
        isFalse,
      );
      expect(triageIsDue(now.subtract(const Duration(hours: 24)), now), isTrue);
    });

    test('candidates are open captures that have text', () {
      expect(
        triageCandidates(<Recording>[
          capture('open'),
          capture('closed', processed: true),
          capture('blank', text: '  '),
          capture('none', text: null),
        ]).map((Recording r) => r.id),
        <String>['open'],
      );
    });

    test('a digest and a decision round-trip through JSON', () {
      final TriageDigest digest = TriageDigest(
        at: DateTime.utc(2026, 10, 3, 8),
        proposals: const <TriageProposal>[
          TriageProposal(
            kind: TriageKind.rerank,
            reason: 'Deadline Friday',
            captureIds: <String>['a'],
            priority: CapturePriority.p0,
          ),
        ],
      );
      final TriageDigest back = TriageDigest.fromJson(
        jsonDecode(jsonEncode(digest.toJson())),
      )!;
      expect(back.at, digest.at);
      expect(back.proposals.single.key, digest.proposals.single.key);
      expect(back.proposals.single.reason, 'Deadline Friday');

      final TriageDecision decision = TriageDecision(
        key: 'merge:a,b',
        outcome: TriageOutcome.rejected,
        at: DateTime.utc(2026, 10, 3, 9),
      );
      final TriageDecision decisionBack = TriageDecision.fromJson(
        jsonDecode(jsonEncode(decision.toJson())),
      )!;
      expect(decisionBack.key, 'merge:a,b');
      expect(decisionBack.outcome, TriageOutcome.rejected);
    });
  });

  group('HttpDailyTriageService', () {
    final List<Recording> open = <Recording>[
      capture('one', text: 'Buy a domain'),
      capture('two', text: 'Buy the domain name'),
      capture('done', text: 'Sent the invoice', processed: true),
    ];

    test('sends only open captures and drops invented or closed ids', () async {
      late Map<String, dynamic> request;
      MeasuredUsage? reported;
      final HttpDailyTriageService service = HttpDailyTriageService(
        activeProfile: () => profile,
        clock: () => DateTime.utc(2026, 10, 3, 8),
        recordUsage:
            ({
              required day,
              required provider,
              required model,
              required usage,
            }) {
              reported = usage;
            },
        client: MockClient((http.Request sent) async {
          request =
              jsonDecode(utf8.decode(sent.bodyBytes)) as Map<String, dynamic>;
          return modelReply(
            <String, dynamic>{
              'proposals': <dynamic>[
                <String, dynamic>{
                  'kind': 'merge',
                  'reason': 'Same errand twice.',
                  'captureIds': <String>['one', 'two', 'one'],
                },
                <String, dynamic>{
                  'kind': 'close',
                  'reason': 'Invented.',
                  'captureIds': <String>['invented'],
                },
                <String, dynamic>{
                  'kind': 'close',
                  'reason': 'Already closed, not in the input.',
                  'captureIds': <String>['done'],
                },
                <String, dynamic>{
                  'kind': 'merge',
                  'reason': 'A merge needs two.',
                  'captureIds': <String>['one'],
                },
                <String, dynamic>{
                  'kind': 'rerank',
                  'reason': 'No target rank.',
                  'captureIds': <String>['two'],
                },
                <String, dynamic>{
                  'kind': 'rerank',
                  'reason': 'The client is waiting.',
                  'captureIds': <String>['two'],
                  'priority': 'P0',
                },
                <String, dynamic>{
                  'kind': 'teleport',
                  'reason': 'Unknown kind.',
                  'captureIds': <String>['two'],
                },
              ],
            },
            usage: <String, int>{'prompt_tokens': 50, 'completion_tokens': 9},
          );
        }),
      );

      final TriageDigest digest = await service.triage(open);
      final List<dynamic> sent =
          jsonDecode(
                ((request['messages'] as List<dynamic>).last
                        as Map<String, dynamic>)['content']
                    as String,
              )
              as List<dynamic>;
      expect(sent.map((dynamic c) => c['id']), <String>['one', 'two']);
      expect(digest.at, DateTime.utc(2026, 10, 3, 8));
      expect(digest.proposals.map((TriageProposal p) => p.kind), <TriageKind>[
        TriageKind.merge,
        TriageKind.rerank,
      ]);
      expect(digest.proposals.first.captureIds, <String>['one', 'two']);
      expect(digest.proposals.last.priority, CapturePriority.p0);
      expect(reported?.inputTokens, 50);
      service.close();
    });

    test('no open captures produces an empty digest without a call', () async {
      int requests = 0;
      final HttpDailyTriageService service = HttpDailyTriageService(
        activeProfile: () => profile,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final TriageDigest digest = await service.triage(<Recording>[
        capture('done', processed: true),
      ]);
      expect(digest.proposals, isEmpty);
      expect(requests, 0);
      service.close();
    });

    test('missing configuration, model failure and malformed output fail '
        'with readable messages', () async {
      final HttpDailyTriageService disabled = HttpDailyTriageService(
        activeProfile: () => null,
      );
      await expectLater(
        disabled.triage(open),
        throwsA(isA<TriageNotConfiguredException>()),
      );
      disabled.close();

      final HttpDailyTriageService failing = HttpDailyTriageService(
        activeProfile: () => profile,
        client: MockClient((_) async => http.Response('overloaded', 503)),
      );
      await expectLater(
        failing.triage(open),
        throwsA(
          isA<HttpException>().having(
            (HttpException e) => e.message,
            'message',
            contains('Daily triage'),
          ),
        ),
      );
      failing.close();

      final HttpDailyTriageService malformed = HttpDailyTriageService(
        activeProfile: () => profile,
        client: MockClient((_) async => modelReply('not json at all')),
      );
      await expectLater(
        malformed.triage(open),
        throwsA(isA<TriageResponseException>()),
      );
      malformed.close();

      final HttpDailyTriageService inventedOnly = HttpDailyTriageService(
        activeProfile: () => profile,
        client: MockClient(
          (_) async => modelReply(<String, dynamic>{
            'proposals': <dynamic>[
              <String, dynamic>{
                'kind': 'close',
                'reason': 'Invented',
                'captureIds': <String>['ghost'],
              },
            ],
          }),
        ),
      );
      await expectLater(
        inventedOnly.triage(open),
        throwsA(isA<TriageResponseException>()),
      );
      inventedOnly.close();
    });

    test('public http is refused before a request is sent', () async {
      int requests = 0;
      final HttpDailyTriageService service = HttpDailyTriageService(
        activeProfile: () => const ProviderProfile(
          id: 'p',
          name: 'Model',
          endpoint: 'http://api.example.com/v1/chat/completions',
          kind: ProfileKind.enrichment,
        ),
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.triage(open),
        throwsA(isA<InsecureTriageEndpointException>()),
      );
      expect(requests, 0);
      service.close();
    });
  });

  group('FileTriageLog', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('triage-log'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('appends digests and decisions and reads them back', () async {
      final FileTriageLog log = FileTriageLog(directory: () async => temp);
      expect((await log.load()).latest, isNull);
      await log.appendDigest(
        TriageDigest(
          at: DateTime.utc(2026, 10, 1),
          proposals: const <TriageProposal>[
            TriageProposal(
              kind: TriageKind.close,
              reason: 'old',
              captureIds: <String>['a'],
            ),
          ],
        ),
      );
      await log.appendDigest(
        TriageDigest(
          at: DateTime.utc(2026, 10, 2),
          proposals: const <TriageProposal>[
            TriageProposal(
              kind: TriageKind.stale,
              reason: 'new',
              captureIds: <String>['b'],
            ),
          ],
        ),
      );
      await log.appendDecision(
        TriageDecision(
          key: 'stale:b',
          outcome: TriageOutcome.rejected,
          at: DateTime.utc(2026, 10, 2, 1),
        ),
      );

      final File file = File('${temp.path}/triage.jsonl');
      // Appended, never rewritten: three rows, and a torn tail costs one row.
      expect(file.readAsLinesSync(), hasLength(3));
      file.writeAsStringSync('{"type":"dig', mode: FileMode.append);

      final TriageHistory history = await FileTriageLog(
        directory: () async => temp,
      ).load();
      expect(history.latest?.at, DateTime.utc(2026, 10, 2));
      expect(history.latest?.proposals.single.reason, 'new');
      expect(history.rejected, <String>{'stale:b'});
    });

    test('a row whose ids do not fit its kind is dropped on load', () async {
      // A hand edit or a merged-in archive can carry rows the service would
      // never have written. Loaded as-is, a rerank with no id made the queue
      // toolbar throw on `captureIds.single`.
      Map<String, dynamic> row(String kind, List<String> ids) =>
          <String, dynamic>{
            'kind': kind,
            'reason': 'r',
            'captureIds': ids,
            if (kind == 'rerank') 'priority': 'p0',
          };
      File('${temp.path}/triage.jsonl').writeAsStringSync(
        '${jsonEncode(<String, dynamic>{
          'type': 'digest',
          'at': '2026-10-02T00:00:00.000Z',
          'proposals': <Map<String, dynamic>>[
            row('rerank', <String>[]),
            row('rerank', <String>['a', 'b']),
            row('merge', <String>['a']),
            row('merge', <String>['a', 'a']),
            row('close', <String>[]),
            row('stale', <String>[]),
            row('close', <String>['c']),
          ],
        })}\n',
      );

      final FileTriageLog log = FileTriageLog(directory: () async => temp);
      final TriageHistory history = await log.load();
      expect(
        history.latest?.proposals.map((TriageProposal p) => p.key),
        <String>['close:c'],
      );

      final DailyTriageController controller = DailyTriageController(
        service: ScriptedService((_) => throw StateError('not run')),
        log: log,
        recordings: () => <Recording>[capture('a'), capture('b'), capture('c')],
        actions: RecordingActions(),
      );
      await controller.load();
      expect(controller.proposals.map((TriageProposal p) => p.key), <String>[
        'close:c',
      ]);
    });
  });

  group('DailyTriageController', () {
    late List<Recording> recordings;
    late MemoryTriageLog log;
    late RecordingActions actions;
    late DateTime now;

    const TriageProposal merge = TriageProposal(
      kind: TriageKind.merge,
      reason: 'Same errand.',
      captureIds: <String>['one', 'two'],
    );
    const TriageProposal close = TriageProposal(
      kind: TriageKind.close,
      reason: 'Done already.',
      captureIds: <String>['three'],
    );
    const TriageProposal rerank = TriageProposal(
      kind: TriageKind.rerank,
      reason: 'Client waiting.',
      captureIds: <String>['two'],
      priority: CapturePriority.p0,
    );

    DailyTriageController build(DailyTriageService service) =>
        DailyTriageController(
          service: service,
          log: log,
          recordings: () => recordings,
          actions: actions,
          clock: () => now,
        );

    setUp(() {
      recordings = <Recording>[
        capture('one', at: DateTime(2026, 9, 1)),
        capture('two', at: DateTime(2026, 9, 2)),
        capture('three'),
      ];
      log = MemoryTriageLog();
      actions = RecordingActions();
      now = DateTime(2026, 10, 3, 9);
    });

    test('running triage persists a digest and touches no capture', () async {
      final List<String> before = recordings
          .map((Recording r) => jsonEncode(r.toJson()))
          .toList();
      final DailyTriageController controller = build(
        ScriptedService(
          (_) async => TriageDigest(
            at: now,
            proposals: const <TriageProposal>[merge, close, rerank],
          ),
        ),
      );
      await controller.load();
      await controller.run();

      expect(controller.error, isNull);
      expect(controller.proposals, hasLength(3));
      expect(log.digests, hasLength(1));
      expect(actions.calls, isEmpty);
      expect(
        recordings.map((Recording r) => jsonEncode(r.toJson())).toList(),
        before,
      );
    });

    test(
      'accepting calls the controller entry points and is remembered',
      () async {
        final DailyTriageController controller = build(
          ScriptedService(
            (_) async => TriageDigest(
              at: now,
              proposals: const <TriageProposal>[merge, close, rerank],
            ),
          ),
        );
        await controller.load();
        await controller.run();

        await controller.accept(merge);
        await controller.accept(close);
        await controller.accept(rerank);
        // A merge keeps the oldest capture and closes the rest.
        expect(actions.calls, <String>[
          'close:two',
          'close:three',
          'priority:two:p0',
        ]);
        expect(controller.proposals, isEmpty);
        expect(
          log.decisions.map((TriageDecision d) => d.outcome).toSet(),
          <TriageOutcome>{TriageOutcome.accepted},
        );
      },
    );

    test('an accepted proposal can come back in a later digest', () async {
      // Accepting answers this digest. If the user later undoes it by hand,
      // a later run must be free to propose the same change again.
      final ScriptedService service = ScriptedService(
        (_) async =>
            TriageDigest(at: now, proposals: const <TriageProposal>[rerank]),
      );
      final DailyTriageController today = build(service);
      await today.load();
      await today.run();
      now = now.add(const Duration(minutes: 5));
      await today.accept(rerank);
      expect(today.proposals, isEmpty);

      // Same digest, fresh controller: the answer is still remembered.
      final DailyTriageController reloaded = build(service);
      await reloaded.load();
      expect(reloaded.proposals, isEmpty);

      // Next day, the model proposes it again: shown, in this session and
      // after a reload.
      now = now.add(const Duration(days: 1));
      await today.run();
      expect(today.proposals.map((TriageProposal p) => p.key), <String>[
        rerank.key,
      ]);
      final DailyTriageController tomorrow = build(service);
      await tomorrow.load();
      expect(tomorrow.proposals.map((TriageProposal p) => p.key), <String>[
        rerank.key,
      ]);
    });

    test('a rejected proposal does not reappear the next day', () async {
      final ScriptedService service = ScriptedService(
        (_) async => TriageDigest(
          at: now,
          proposals: const <TriageProposal>[merge, close],
        ),
      );
      final DailyTriageController today = build(service);
      await today.load();
      await today.run();
      await today.reject(merge);
      expect(today.proposals.map((TriageProposal p) => p.key), <String>[
        close.key,
      ]);
      expect(actions.calls, isEmpty);

      // Next day, a fresh controller over the same log, and the model
      // proposes the same merge again in different words.
      now = now.add(const Duration(days: 1));
      service.answer = (_) async => TriageDigest(
        at: now,
        proposals: const <TriageProposal>[
          TriageProposal(
            kind: TriageKind.merge,
            reason: 'Reworded.',
            captureIds: <String>['two', 'one'],
          ),
          close,
        ],
      );
      final DailyTriageController tomorrow = build(service);
      await tomorrow.load();
      await tomorrow.runIfDue();
      expect(service.calls, 2);
      expect(tomorrow.proposals.map((TriageProposal p) => p.key), <String>[
        close.key,
      ]);
    });

    test('proposals citing captures that left the desk are hidden', () async {
      final DailyTriageController controller = build(
        ScriptedService(
          (_) async => TriageDigest(
            at: now,
            proposals: const <TriageProposal>[merge, close],
          ),
        ),
      );
      await controller.load();
      await controller.run();
      recordings = <Recording>[
        capture('one'),
        capture('two'),
        capture('three', processed: true),
      ];
      expect(controller.proposals.map((TriageProposal p) => p.key), <String>[
        merge.key,
      ]);
    });

    test('runIfDue runs once per 24 hours of digests', () async {
      final ScriptedService service = ScriptedService(
        (_) async => TriageDigest(at: now, proposals: const <TriageProposal>[]),
      );
      final DailyTriageController controller = build(service);
      await controller.load();
      await controller.runIfDue();
      await controller.runIfDue();
      expect(service.calls, 1);
      now = now.add(const Duration(hours: 25));
      await controller.runIfDue();
      expect(service.calls, 2);
    });

    test(
      'failures degrade to a message and do not retry on every resume',
      () async {
        final ScriptedService service = ScriptedService(
          (_) async => throw const TriageNotConfiguredException(),
        );
        final DailyTriageController controller = build(service);
        await controller.load();
        await controller.runIfDue();
        expect(
          controller.error,
          'Configure an enrichment model in Models first.',
        );
        expect(controller.isRunning, isFalse);
        await controller.runIfDue();
        expect(service.calls, 1);
        expect(log.digests, isEmpty);

        service.answer = (_) async => throw const TriageResponseException();
        await controller.run();
        expect(controller.error, contains('unreadable'));

        service.answer = (_) async => throw StateError('socket closed');
        await controller.run();
        expect(controller.error, startsWith('Triage failed'));
      },
    );

    test('a run still in flight at dispose does not notify', () async {
      // The page starts the launch/resume run unawaited and disposes the
      // controller on teardown, so a run can outlive its listeners. Notifying
      // a disposed ChangeNotifier asserts in debug.
      final Completer<TriageDigest> answer = Completer<TriageDigest>();
      final DailyTriageController controller = build(
        ScriptedService((_) => answer.future),
      );
      await controller.load();
      final Future<void> running = controller.run();
      controller.dispose();
      answer.complete(
        TriageDigest(at: now, proposals: const <TriageProposal>[close]),
      );
      await running;
      await controller.load();
      await controller.reject(close);
      await controller.accept(close);
      expect(controller.isRunning, isFalse);
    });

    test('an unreadable log blocks the automatic run', () async {
      log.failLoad = true;
      final ScriptedService service = ScriptedService(
        (_) async => TriageDigest(at: now, proposals: const <TriageProposal>[]),
      );
      final DailyTriageController controller = build(service);
      await controller.load();
      expect(controller.historyUnreadable, isTrue);
      await controller.runIfDue();
      expect(service.calls, 0);
    });
  });
}

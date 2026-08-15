import 'dart:io';

import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/command_router.dart';
import 'package:augustyniak_capture/features/recordings/data/project_inbox_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Records every exchange instead of making one, so a test can assert both what
/// was sent and — for the retry case — that two deliveries carried one key.
class _FakeCommandClient implements CommandClient {
  _FakeCommandClient({this.briefFailure, this.sessionFailure});

  final Object? briefFailure;
  final Object? sessionFailure;

  final List<Map<String, String>> briefs = <Map<String, String>>[];
  final List<String> sessionsFor = <String>[];

  @override
  bool get isConfigured => true;

  @override
  Future<List<CommandHost>> hosts() async => const <CommandHost>[];

  @override
  Future<List<CommandWorkspace>> workspaces(String hostId) async =>
      const <CommandWorkspace>[];

  @override
  Future<CommandBrief> putBrief({
    required String host,
    required String workspace,
    required String captureId,
    required String content,
  }) async {
    if (briefFailure != null) throw briefFailure!;
    briefs.add(<String, String>{
      'host': host,
      'workspace': workspace,
      'capture_id': captureId,
      'content': content,
    });
    return CommandBrief(id: 'brief-${briefs.length}');
  }

  @override
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  }) async {
    if (sessionFailure != null) throw sessionFailure!;
    sessionsFor.add(briefId);
    return const CommandSession(name: 'plan-capture-01');
  }
}

Project _project({
  String repoPath = '/tmp/acme',
  bool bound = true,
}) => Project(
  id: 'p1',
  name: 'Acme',
  repoPath: repoPath,
  commandHost: bound ? 'studio' : null,
  commandWorkspace: bound ? 'capture' : null,
);

RoutedCapture _capture({
  String id = 'cap-1',
  CaptureCategory? category = CaptureCategory.agentTask,
}) => RoutedCapture(
  id: id,
  projectId: 'p1',
  title: 'Split the router',
  body: 'Split the tokenizer out of the parser.',
  summary: 'Router split agreed.',
  category: category,
  tags: const <String>['backend'],
  type: CaptureType.audioRecording,
  capturedAt: DateTime.utc(2026, 8, 15, 9),
);

void main() {
  group('canRoute answers from configuration, never the network', () {
    test('a bound project can route; an unbound one cannot', () {
      final _FakeCommandClient client = _FakeCommandClient();
      expect(
        CommandRouter(
          projectById: (String _) => _project(),
          client: client,
        ).canRoute('p1'),
        isTrue,
      );
      expect(
        CommandRouter(
          projectById: (String _) => _project(bound: false),
          client: client,
        ).canRoute('p1'),
        isFalse,
      );
      // Not one request was made to answer either question.
      expect(client.briefs, isEmpty);
      expect(client.sessionsFor, isEmpty);
    });

    test('a collector that is down still leaves the button enabled', () {
      // The delivery fails and the capture stays on the desk; the control does
      // not disappear, because that would require polling a machine to decide
      // whether to draw a button.
      final CommandRouter router = CommandRouter(
        projectById: (String _) => _project(),
        client: _FakeCommandClient(
          briefFailure: const SocketException('no route to host'),
        ),
      );
      expect(router.canRoute('p1'), isTrue);
    });
  });

  group('delivery', () {
    test('files the brief, then starts the session, and records where', () async {
      final _FakeCommandClient client = _FakeCommandClient();
      final RouteRecord record = await CommandRouter(
        projectById: (String _) => _project(),
        client: client,
      ).route(_capture());

      expect(client.briefs.single['host'], 'studio');
      expect(client.briefs.single['workspace'], 'capture');
      expect(client.briefs.single['capture_id'], 'cap-1');
      // The brief is the format the local launcher writes — one serializer.
      expect(client.briefs.single['content'], startsWith('---\n'));
      expect(client.briefs.single['content'], contains('capture-id: cap-1'));
      expect(client.briefs.single['content'], contains('Split the tokenizer'));

      expect(client.sessionsFor, <String>['brief-1']);
      expect(record.kind, RouteKind.command);
      expect(record.target, 'studio · capture · plan-capture-01');
    });

    test('a failed PUT starts no session and records nothing', () async {
      final _FakeCommandClient client = _FakeCommandClient(
        briefFailure: const HttpException('Filing the brief failed (503).'),
      );

      await expectLater(
        CommandRouter(
          projectById: (String _) => _project(),
          client: client,
        ).route(_capture()),
        throwsA(isA<HttpException>()),
      );
      expect(client.sessionsFor, isEmpty);
    });

    test('a landed brief with no session says so, and says retrying is safe', () async {
      final _FakeCommandClient client = _FakeCommandClient(
        sessionFailure: const HttpException('Starting the session failed (500).'),
      );

      await expectLater(
        CommandRouter(
          projectById: (String _) => _project(),
          client: client,
        ).route(_capture()),
        throwsA(
          isA<CommandSessionNotStartedException>().having(
            (CommandSessionNotStartedException e) => e.toString(),
            'message',
            allOf(
              // "Lost" and "queued but unstarted" call for opposite next
              // actions, so the message has to separate them.
              contains('no session started'),
              contains('studio · capture'),
              contains('Retrying is safe'),
            ),
          ),
        ),
      );
      // The brief did land, which is the whole point of the distinction.
      expect(client.briefs, hasLength(1));
    });

    test('a retried delivery carries the same capture_id', () async {
      final _FakeCommandClient client = _FakeCommandClient();
      final CommandRouter router = CommandRouter(
        projectById: (String _) => _project(),
        client: client,
      );

      await router.route(_capture());
      await router.route(_capture());

      expect(client.briefs, hasLength(2));
      expect(
        client.briefs.map((Map<String, String> brief) => brief['capture_id']),
        <String>['cap-1', 'cap-1'],
      );
    });

    test('an unbound project is refused rather than half-addressed', () async {
      await expectLater(
        CommandRouter(
          projectById: (String _) => _project(bound: false),
          client: _FakeCommandClient(),
        ).route(_capture()),
        throwsA(isA<CaptureRoutingUnavailableException>()),
      );
    });
  });

  group('which destination a capture gets', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('augustyniak_command_');
    });

    tearDown(() => repo.deleteSync(recursive: true));

    ProjectCaptureRouter routerFor(
      _FakeCommandClient client, {
      bool bound = true,
    }) => ProjectCaptureRouter(
      command: CommandRouter(
        projectById: (String _) => _project(repoPath: repo.path, bound: bound),
        client: client,
      ),
      fallback: ProjectInboxRouter(
        projectById: (String _) =>
            _project(repoPath: repo.path, bound: bound),
      ),
    );

    test('an agentTask on a bound project goes to the control plane', () async {
      final _FakeCommandClient client = _FakeCommandClient();
      final RouteRecord record = await routerFor(client).route(_capture());

      expect(record.kind, RouteKind.command);
      expect(client.briefs, hasLength(1));
      expect(File(p.join(repo.path, 'inbox.md')).existsSync(), isFalse);
    });

    test('any other category on the same project goes to the inbox', () async {
      final _FakeCommandClient client = _FakeCommandClient();
      final RouteRecord record = await routerFor(
        client,
      ).route(_capture(category: CaptureCategory.note));

      expect(record.kind, RouteKind.file);
      expect(client.briefs, isEmpty);
      expect(File(p.join(repo.path, 'inbox.md')).existsSync(), isTrue);
    });

    test('an unclassified capture goes to the inbox, not the fleet', () async {
      // Null means enrichment never ran, which is not a decision to delegate.
      final _FakeCommandClient client = _FakeCommandClient();
      final RouteRecord record = await routerFor(
        client,
      ).route(_capture(category: null));

      expect(record.kind, RouteKind.file);
      expect(client.briefs, isEmpty);
    });

    test('an unbound project still reaches the local destination', () async {
      final _FakeCommandClient client = _FakeCommandClient();
      final RouteRecord record = await routerFor(
        client,
        bound: false,
      ).route(_capture());

      expect(record.kind, RouteKind.file);
      expect(client.briefs, isEmpty);
      expect(File(p.join(repo.path, 'inbox.md')).existsSync(), isTrue);
    });

    test('canRoute is the union of both destinations', () {
      final ProjectCaptureRouter bound = routerFor(_FakeCommandClient());
      final ProjectCaptureRouter unbound = routerFor(
        _FakeCommandClient(),
        bound: false,
      );
      expect(bound.canRoute('p1'), isTrue);
      // Unbound but with a repository: the inbox still takes it.
      expect(unbound.canRoute('p1'), isTrue);
    });
  });

  group('the route kind', () {
    test('command round-trips, and an older build drops only that row', () {
      final RouteRecord record = RouteRecord(
        at: DateTime.utc(2026, 8, 15, 9),
        kind: RouteKind.command,
        target: 'studio · capture · plan-capture-01',
      );
      expect(RouteRecord.fromJson(record.toJson())!.kind, RouteKind.command);

      // The stated cost of a new kind: a build that predates it cannot read the
      // row and drops it rather than claiming the capture went somewhere else.
      expect(RouteKind.fromName('somethingNewer'), isNull);
    });
  });
}

import 'dart:io';

import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Answers about briefs and counts how often it was asked, which is the only
/// way to assert that a poll *stopped*.
class _FakeCommandClient implements CommandClient {
  _FakeCommandClient({this.status, this.failure});

  final CommandBriefStatus? status;
  final Object? failure;
  final List<String> asked = <String>[];

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
  }) async => throw UnimplementedError();

  @override
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  }) async => throw UnimplementedError();

  @override
  Future<CommandBriefStatus> briefStatus(String briefId) async {
    asked.add(briefId);
    if (failure != null) throw failure!;
    return status!;
  }
}

RouteRecord _delivered({
  CommandState state = CommandState.submitted,
  DateTime? checkedAt,
}) => RouteRecord(
  at: DateTime.utc(2026, 8, 15, 9),
  kind: RouteKind.command,
  target: 'studio · capture · plan-capture-01',
  outcome: RouteOutcome(
    briefId: 'brief-1',
    state: state,
    checkedAt: checkedAt ?? DateTime.utc(2026, 8, 15, 9),
  ),
);

void main() {
  group('RouteOutcome on disk', () {
    test('round-trips, and an absent one is not invented', () {
      final RouteRecord record = _delivered(state: CommandState.inProgress);
      final RouteRecord read = RouteRecord.fromJson(record.toJson())!;

      expect(read.outcome!.briefId, 'brief-1');
      expect(read.outcome!.state, CommandState.inProgress);
      expect(read.outcome!.checkedAt, DateTime.utc(2026, 8, 15, 9));

      final RouteRecord file = RouteRecord(
        at: DateTime.utc(2026, 8, 15, 9),
        kind: RouteKind.file,
        target: 'inbox.md · Acme',
      );
      expect(file.toJson().containsKey('outcome'), isFalse);
      expect(RouteRecord.fromJson(file.toJson())!.outcome, isNull);
    });

    test('a build that predates the field keeps the row', () {
      // Exactly what an older `toJson` wrote.
      final RouteRecord? read = RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-08-15T09:00:00.000Z',
        'kind': 'command',
        'target': 'studio · capture · plan-capture-01',
      });

      expect(read, isNotNull);
      expect(read!.outcome, isNull);
    });

    test('an unreadable outcome costs the outcome, never the record', () {
      // A state a newer build named. Guessing would show a capture as `done`
      // because this build cannot read the word for it.
      final RouteRecord? read = RouteRecord.fromJson(<String, dynamic>{
        'at': '2026-08-15T09:00:00.000Z',
        'kind': 'command',
        'target': 'studio · capture · plan-capture-01',
        'outcome': <String, dynamic>{
          'briefId': 'brief-1',
          'state': 'awaitingSomethingNewer',
          'checkedAt': '2026-08-15T09:00:00.000Z',
        },
      });

      expect(read, isNotNull);
      expect(read!.target, 'studio · capture · plan-capture-01');
      expect(read.outcome, isNull);
      expect(CommandState.fromName('awaitingSomethingNewer'), isNull);
    });
  });

  group('refreshCommandOutcomes', () {
    late Directory appDir;

    setUp(() {
      appDir = Directory.systemTemp.createTempSync('augustyniak_outcome_');
    });

    tearDown(() => appDir.deleteSync(recursive: true));

    Future<RecordingsController> seed(
      CommandClient client, {
      RouteRecord? route,
    }) => buildRecordingsController(
      appDir,
      commandClient: client,
      seed: <Recording>[
        makeRecording(
          id: 'r1',
          isProcessedByUser: true,
          routes: <RouteRecord>[route ?? _delivered()],
        ),
      ],
    );

    test('an answer moves the state and stamps when it was asked', () async {
      final _FakeCommandClient client = _FakeCommandClient(
        status: const CommandBriefStatus(
          briefId: 'brief-1',
          state: CommandState.inProgress,
          issues: <int>[41, 42],
          prUrl: 'https://github.com/acme/repo/pull/7',
        ),
      );
      final RecordingsController controller = await seed(client);

      expect(await controller.refreshCommandOutcomes(), 1);
      final RouteOutcome outcome =
          controller.recordings.single.routes.single.outcome!;
      expect(outcome.state, CommandState.inProgress);
      expect(outcome.issues, <int>[41, 42]);
      expect(outcome.prUrl, 'https://github.com/acme/repo/pull/7');
      expect(outcome.checkedAt.isAfter(DateTime.utc(2026, 8, 15, 9)), isTrue);
    });

    test('an unreachable aggregator keeps the last answer and its time', () async {
      final DateTime known = DateTime.utc(2026, 8, 15, 9);
      final _FakeCommandClient client = _FakeCommandClient(
        failure: const SocketException('no route to host'),
      );
      final RecordingsController controller = await seed(
        client,
        route: _delivered(state: CommandState.planned, checkedAt: known),
      );

      expect(await controller.refreshCommandOutcomes(), 0);
      final RouteOutcome outcome =
          controller.recordings.single.routes.single.outcome!;
      // Clearing would turn "nobody has looked lately" into "nothing has
      // happened", which are different facts.
      expect(outcome.state, CommandState.planned);
      expect(outcome.checkedAt, known);
    });

    test('a 404 stops the polling instead of retrying forever', () async {
      final _FakeCommandClient client = _FakeCommandClient(
        failure: const CommandBriefGoneException('brief-1'),
      );
      final RecordingsController controller = await seed(client);

      await controller.refreshCommandOutcomes();
      await controller.refreshCommandOutcomes();
      await controller.refreshCommandOutcomes();

      expect(client.asked, <String>['brief-1']);
    });

    test('a capture routed to a file is never asked about', () async {
      final _FakeCommandClient client = _FakeCommandClient(
        status: const CommandBriefStatus(
          briefId: 'brief-1',
          state: CommandState.done,
        ),
      );
      final RecordingsController controller = await seed(
        client,
        route: RouteRecord(
          at: DateTime.utc(2026, 8, 15, 9),
          kind: RouteKind.file,
          target: 'inbox.md · Acme',
        ),
      );

      expect(await controller.refreshCommandOutcomes(), 0);
      expect(client.asked, isEmpty);
    });

    test('an install with no control plane does nothing and does not throw', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'r1', routes: <RouteRecord>[_delivered()]),
        ],
      );

      expect(await controller.refreshCommandOutcomes(), 0);
    });
  });

  group('where an outcome links to', () {
    late Directory appDir;

    setUp(() {
      appDir = Directory.systemTemp.createTempSync('augustyniak_outcome_url_');
    });

    tearDown(() => appDir.deleteSync(recursive: true));

    Future<RecordingsController> build({String? baseUrl}) =>
        buildRecordingsController(appDir, commandBaseUrl: () => baseUrl);

    test('the pull request wins when there is one', () async {
      final RecordingsController controller = await build(
        baseUrl: 'https://fleet.example',
      );
      expect(
        controller
            .commandOutcomeUrl(
              RouteOutcome(
                briefId: 'brief-1',
                state: CommandState.needsReview,
                checkedAt: DateTime.utc(2026, 8, 15),
                prUrl: 'https://github.com/acme/repo/pull/7',
              ),
            )
            .toString(),
        'https://github.com/acme/repo/pull/7',
      );
    });

    test('otherwise the brief page on the configured aggregator', () async {
      final RecordingsController controller = await build(
        baseUrl: 'https://fleet.example/command',
      );
      expect(
        controller
            .commandOutcomeUrl(
              RouteOutcome(
                briefId: 'brief-1',
                state: CommandState.planned,
                checkedAt: DateTime.utc(2026, 8, 15),
              ),
            )
            .toString(),
        'https://fleet.example/command/briefs/brief-1',
      );
    });

    test('nothing to open when nothing is configured', () async {
      final RecordingsController controller = await build();
      expect(
        controller.commandOutcomeUrl(
          RouteOutcome(
            briefId: 'brief-1',
            state: CommandState.planned,
            checkedAt: DateTime.utc(2026, 8, 15),
          ),
        ),
        isNull,
      );
    });
  });
}

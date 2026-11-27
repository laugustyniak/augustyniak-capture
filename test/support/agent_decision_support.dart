import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_decision.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Shared by the #474 controller and drainer tests.
///
/// Uses the types #474 creates in `agent_decision.dart`:
/// `AgentDecision({decisionId, captureId, version, action, reason, did,
/// target, agent, submittedAt})`, `AgentDecisionAction`, and
/// `DecisionOutcome` with `.kind` (`DecisionOutcomeKind.applied |
/// alreadyClosed | rejected`) and `.reason`.

class CollectingLog implements LogSink {
  final List<({String message, LogLevel level})> entries =
      <({String message, LogLevel level})>[];

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) => entries.add((message: message, level: level));

  bool mentions(String needle) =>
      entries.any((e) => e.message.toLowerCase().contains(needle));
}

class CollectingClosureLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => List<ClosureEvent>.of(appended);

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

/// A router whose delivery the test controls.
class ScriptedRouter implements CaptureRouter {
  ScriptedRouter({this.kind = RouteKind.file});

  RouteKind kind;
  bool fail = false;
  int calls = 0;

  /// Runs in the middle of a delivery, before it completes.
  Future<void> Function()? during;

  @override
  bool canRoute(String? projectId) => true;

  @override
  RouteKind? resolvedKind(RoutedCapture capture) => kind;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    calls++;
    await during?.call();
    if (fail) throw const FileSystemException('repo is gone');
    return RouteRecord(
      at: DateTime.now(),
      kind: kind,
      target: 'inbox.md · Acme',
    );
  }
}

class SwitchableRepository extends FakeRecordingsRepository {
  SwitchableRepository(super.directory, {super.seed});

  bool failWrites = false;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    if (failWrites) {
      saveCalls++;
      throw const FileSystemException('disk full');
    }
    await super.saveAll(recordings);
  }
}

/// Where seeded source files live: always a test-owned temp directory, so a
/// delete in a test can never unlink something under the real `/tmp`.
Directory? seedDirectory;

/// A capture whose hash is already known, so the startup backfill does not
/// add a hidden `saveAll` that a test would mistake for the apply.
Recording seedRecording(
  String id, {
  bool processed = false,
  DateTime? resurfaceAt,
  int? repeatEveryDays,
  List<RouteRecord> routes = const <RouteRecord>[],
}) =>
    makeRecording(
      id: id,
      title: 'Capture $id',
      transcript: 'text of $id',
      projectId: 'p1',
      isProcessedByUser: processed,
      routes: routes,
    ).copyWith(
      contentHash: 'a' * 64,
      resurfaceAt: resurfaceAt,
      repeatEveryDays: repeatEveryDays,
    );

Future<RecordingsController> buildController(
  RecordingsRepository repository, {
  ScriptedRouter? router,
  CollectingLog? log,
  CollectingClosureLog? closures,
  bool initialize = true,
}) async {
  final RecordingsController controller = RecordingsController(
    repository: repository,
    transcriptionService: const DisabledTranscriptionService(),
    recorder: FakeRecorder(),
    player: FakePlayer(),
    captureRouter: router ?? ScriptedRouter(),
    logSink: log ?? CollectingLog(),
    closureLog: closures ?? CollectingClosureLog(),
  );
  addTearDown(controller.dispose);
  if (initialize) {
    await controller.initialize();
    await controller.loadClosures();
    await controller.waitForProcessing();
  }
  return controller;
}

/// The version an agent would have read: sha256 of the canonical encoding of
/// the row as the controller holds it. Independent of `recordingVersion`.
String versionOf(RecordingsController controller, String id) {
  final Recording r = controller.recordings.firstWhere(
    (Recording x) => x.id == id,
  );
  return sha256.convert(utf8.encode(jsonEncode(r.toJson()))).toString();
}

const String decisionUuid = '123e4567-e89b-42d3-a456-426614174000';

AgentDecision makeDecision(
  String captureId, {
  required String version,
  AgentDecisionAction action = AgentDecisionAction.done,
  String decisionId = decisionUuid,
  String reason = 'F2: handled it',
  String? did = 'opened PR #12',
  String agent = 'codex',
}) => AgentDecision(
  decisionId: decisionId,
  captureId: captureId,
  version: version,
  action: action,
  reason: reason,
  did: did,
  agent: agent,
  submittedAt: DateTime.utc(2026, 11, 27, 10),
);

Recording byId(RecordingsController c, String id) =>
    c.recordings.firstWhere((Recording r) => r.id == id);

void expectKind(DecisionOutcome o, DecisionOutcomeKind kind, {String? why}) {
  expect(o.kind, kind, reason: 'reason: ${o.reason}');
  if (why != null) expect(o.reason, contains(why));
}

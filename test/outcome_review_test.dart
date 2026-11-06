import 'dart:io';

import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/command/domain/outcome_review.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// The words a capture carries. Nothing derived from them may reach a
/// notification or the speaker — the acceptance criterion "an outcome summary
/// never sends capture text anywhere new".
const String _secretTranscript = 'acquire the competitor quietly';
const String _secretTitle = 'Project Nightjar';
const String _secretSummary = 'A plan nobody else should hear.';

class _StatusClient implements CommandClient {
  _StatusClient(this.state, {this.prUrl});

  CommandState state;
  String? prUrl;

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
  Future<CommandBriefStatus> briefStatus(String briefId) async =>
      CommandBriefStatus(briefId: briefId, state: state, prUrl: prUrl);
}

/// Records what it was asked to show, and how many index writes had happened
/// by then — the only way to see that it ran after the persist.
class _RecordingNotifier implements OutcomeNotifier {
  _RecordingNotifier(this.repository, {this.granted = true, this.failure});

  final _MemoryRepo repository;
  final bool granted;
  final Object? failure;
  final List<OutcomeAnnouncement> shown = <OutcomeAnnouncement>[];
  final List<int> savesWhenShown = <int>[];

  @override
  Future<bool> notify(OutcomeAnnouncement announcement) async {
    savesWhenShown.add(repository.saveCalls);
    if (failure != null) throw failure!;
    if (!granted) return false;
    shown.add(announcement);
    return true;
  }
}

class _RecordingSpeaker implements OutcomeSpeaker {
  _RecordingSpeaker({this.available = true, this.failure});

  final bool available;
  final Object? failure;
  final List<String> spoken = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> speak(String text) async {
    if (failure != null) throw failure!;
    spoken.add(text);
  }
}

class _ThrowingProbeSpeaker implements OutcomeSpeaker {
  @override
  Future<bool> isAvailable() async => throw StateError('engine probe died');

  @override
  Future<void> speak(String text) async {}
}

class _MemoryRepo extends RecordingsRepository {
  _MemoryRepo(this._dir, this.seed);
  final Directory _dir;
  final List<Recording> seed;
  int saveCalls = 0;
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => seed;
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
    saved = List<Recording>.from(recordings);
  }
}

/// Grants the mic and writes [take] to whatever path the controller hands it.
class _GrantingRecorder implements AudioRecorder {
  _GrantingRecorder({this.take = 'ship it after the review'});
  final String take;
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsStringSync(take, flush: true);
    this.path = path;
  }

  @override
  Future<String?> stop() async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _EchoProcessor implements Processor {
  @override
  Future<String> process(CaptureSegment segment) =>
      File(segment.filePath).readAsString();
}

RouteOutcome _outcome(
  CommandState state, {
  String? prUrl,
  List<int> issues = const <int>[],
}) => RouteOutcome(
  briefId: 'brief-1',
  state: state,
  checkedAt: DateTime.utc(2026, 8, 15, 9),
  prUrl: prUrl,
  issues: issues,
);

RouteRecord _route(RouteOutcome? outcome) => RouteRecord(
  at: DateTime.utc(2026, 8, 15, 9),
  kind: RouteKind.command,
  target: 'studio · capture · plan-capture-01',
  outcome: outcome,
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

  group('outcomeNeedsAttention', () {
    test('terminal and needs-attention states announce, the rest do not', () {
      expect(outcomeNeedsAttention(CommandState.done), isTrue);
      expect(outcomeNeedsAttention(CommandState.blocked), isTrue);
      expect(outcomeNeedsAttention(CommandState.needsReview), isTrue);
      expect(outcomeNeedsAttention(CommandState.submitted), isFalse);
      expect(outcomeNeedsAttention(CommandState.planned), isFalse);
      expect(outcomeNeedsAttention(CommandState.inProgress), isFalse);
    });
  });

  group('spokenOutcomeSummary', () {
    test('names the state, the pull request and the issues', () {
      final String summary = spokenOutcomeSummary(
        _route(
          _outcome(
            CommandState.needsReview,
            prUrl: 'https://github.com/acme/repo/pull/7',
            issues: <int>[41, 42],
          ),
        ),
      );

      expect(summary, contains('needs review'));
      expect(summary, contains('pull request 7 in acme/repo'));
      expect(summary, contains('2 issues'));
    });

    test('a pull request link it cannot read is not spelled out', () {
      final String summary = spokenOutcomeSummary(
        _route(_outcome(CommandState.done, prUrl: 'not a url at all')),
      );

      expect(summary, contains('done'));
      expect(summary, contains('a pull request'));
      expect(summary, isNot(contains('not a url')));
    });

    test('one issue is singular, none is not mentioned', () {
      expect(
        spokenOutcomeSummary(
          _route(_outcome(CommandState.blocked, issues: <int>[9])),
        ),
        contains('1 issue'),
      );
      expect(
        spokenOutcomeSummary(_route(_outcome(CommandState.blocked))),
        isNot(contains('issue')),
      );
    });
  });

  group('spoken review through the controller', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outcome-review');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<Recording> seedCapture({
      RouteOutcome? outcome,
      List<RouteRecord>? routes,
    }) async {
      final File file = File(p.join(dir.path, 'abc.txt'));
      await file.writeAsString(_secretTranscript);
      return Recording(
        id: 'abc',
        filePath: file.path,
        createdAt: DateTime.utc(2026, 8, 15),
        durationMs: 0,
        sizeBytes: _secretTranscript.length,
        status: RecordingStatus.completed,
        type: CaptureType.text,
        transcript: _secretTranscript,
        title: _secretTitle,
        summary: _secretSummary,
        isProcessedByUser: true,
        processedAt: DateTime.utc(2026, 8, 15),
        routes:
            routes ??
            <RouteRecord>[_route(outcome ?? _outcome(CommandState.inProgress))],
      );
    }

    RecordingsController build(
      _MemoryRepo repository, {
      CommandClient commandClient = const DisabledCommandClient(),
      OutcomeNotifier outcomeNotifier = const NoopOutcomeNotifier(),
      OutcomeSpeaker outcomeSpeaker = const UnavailableOutcomeSpeaker(),
      AudioRecorder? recorder,
    }) {
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
        commandClient: commandClient,
        outcomeNotifier: outcomeNotifier,
        outcomeSpeaker: outcomeSpeaker,
        recorder: recorder,
        processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
          CaptureType.text: _EchoProcessor(),
          CaptureType.audioRecording: _EchoProcessor(),
        }),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('a change into an attention state is announced once, after the '
        'outcome is persisted', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(),
      ]);
      final _StatusClient client = _StatusClient(
        CommandState.needsReview,
        prUrl: 'https://github.com/acme/repo/pull/7',
      );
      final _RecordingNotifier notifier = _RecordingNotifier(repo);
      final RecordingsController controller = build(
        repo,
        commandClient: client,
        outcomeNotifier: notifier,
      );
      await controller.initialize();
      final int savesBefore = repo.saveCalls;

      expect(await controller.refreshCommandOutcomes(), 1);
      await controller.waitForOutcomeAnnouncements();

      expect(notifier.shown, hasLength(1));
      final OutcomeAnnouncement shown = notifier.shown.single;
      expect(shown.recordingId, 'abc');
      expect(shown.state, CommandState.needsReview);
      expect(shown.summary, contains('pull request 7 in acme/repo'));
      expect(
        notifier.savesWhenShown.single,
        greaterThan(savesBefore),
        reason: 'the notification is a sink: it runs after the persist',
      );
      expect(
        repo.saved.single.routes.last.outcome!.state,
        CommandState.needsReview,
      );

      // Asked again with nothing new: the state did not change, so nothing is
      // announced a second time.
      await controller.refreshCommandOutcomes();
      await controller.waitForOutcomeAnnouncements();
      expect(notifier.shown, hasLength(1));
    });

    test('a change between working states is not announced', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(outcome: _outcome(CommandState.submitted)),
      ]);
      final _RecordingNotifier notifier = _RecordingNotifier(repo);
      final RecordingsController controller = build(
        repo,
        commandClient: _StatusClient(CommandState.inProgress),
        outcomeNotifier: notifier,
      );
      await controller.initialize();

      await controller.refreshCommandOutcomes();
      await controller.waitForOutcomeAnnouncements();

      expect(notifier.savesWhenShown, isEmpty);
    });

    test('a refused or failing notification degrades to the card', () async {
      for (final _RecordingNotifier Function(_MemoryRepo) make
          in <_RecordingNotifier Function(_MemoryRepo)>[
            (_MemoryRepo r) => _RecordingNotifier(r, granted: false),
            (_MemoryRepo r) => _RecordingNotifier(
              r,
              failure: const FileSystemException('no permission'),
            ),
          ]) {
        final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
          await seedCapture(),
        ]);
        final _RecordingNotifier notifier = make(repo);
        final RecordingsController controller = build(
          repo,
          commandClient: _StatusClient(CommandState.done),
          outcomeNotifier: notifier,
        );
        await controller.initialize();

        expect(await controller.refreshCommandOutcomes(), 1);
        await controller.waitForOutcomeAnnouncements();

        expect(notifier.savesWhenShown, hasLength(1));
        expect(controller.error, isNull);
        // The card view is what is left, and it still has the answer.
        expect(
          controller.recordings.single.routes.last.outcome!.state,
          CommandState.done,
        );
      }
    });

    test(
      'listen speaks the outcome summary and nothing of the capture',
      () async {
        final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
          await seedCapture(
            outcome: _outcome(
              CommandState.done,
              prUrl: 'https://github.com/acme/repo/pull/7',
              issues: <int>[41],
            ),
          ),
        ]);
        final _RecordingSpeaker speaker = _RecordingSpeaker();
        final RecordingsController controller = build(
          repo,
          outcomeSpeaker: speaker,
        );
        await controller.initialize();

        expect(await controller.listenToOutcome('abc'), isTrue);

        expect(speaker.spoken, hasLength(1));
        final String spoken = speaker.spoken.single;
        expect(spoken, contains('done'));
        expect(spoken, contains('pull request 7 in acme/repo'));
        for (final String secret in <String>[
          _secretTranscript,
          _secretTitle,
          _secretSummary,
        ]) {
          expect(spoken, isNot(contains(secret)));
        }
      },
    );

    test('an announcement carries nothing of the capture either', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(),
      ]);
      final _RecordingNotifier notifier = _RecordingNotifier(repo);
      final RecordingsController controller = build(
        repo,
        commandClient: _StatusClient(CommandState.blocked),
        outcomeNotifier: notifier,
      );
      await controller.initialize();

      await controller.refreshCommandOutcomes();
      await controller.waitForOutcomeAnnouncements();

      final OutcomeAnnouncement shown = notifier.shown.single;
      for (final String text in <String>[shown.title, shown.summary]) {
        for (final String secret in <String>[
          _secretTranscript,
          _secretTitle,
          _secretSummary,
        ]) {
          expect(text, isNot(contains(secret)));
        }
      }
    });

    test(
      'without a speaker, listen answers false and the card stays',
      () async {
        for (final OutcomeSpeaker speaker in <OutcomeSpeaker>[
          const UnavailableOutcomeSpeaker(),
          _RecordingSpeaker(available: false),
          _RecordingSpeaker(failure: const FileSystemException('tts died')),
        ]) {
          final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
            await seedCapture(outcome: _outcome(CommandState.done)),
          ]);
          final RecordingsController controller = build(
            repo,
            outcomeSpeaker: speaker,
          );
          await controller.initialize();

          expect(await controller.listenToOutcome('abc'), isFalse);
          expect(controller.recordings.single.routes.last.outcome, isNotNull);
          if (speaker is _RecordingSpeaker) expect(speaker.spoken, isEmpty);
        }
      },
    );

    test('listen on a capture with no outcome speaks nothing', () async {
      final File file = File(p.join(dir.path, 'plain.txt'));
      await file.writeAsString('x');
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        Recording(
          id: 'plain',
          filePath: file.path,
          createdAt: DateTime.utc(2026, 8, 15),
          durationMs: 0,
          sizeBytes: 1,
          status: RecordingStatus.completed,
          type: CaptureType.text,
          transcript: 'x',
        ),
      ]);
      final _RecordingSpeaker speaker = _RecordingSpeaker();
      final RecordingsController controller = build(
        repo,
        outcomeSpeaker: speaker,
      );
      await controller.initialize();

      expect(await controller.listenToOutcome('plain'), isFalse);
      expect(await controller.listenToOutcome('missing'), isFalse);
      expect(speaker.spoken, isEmpty);
      expect(controller.outcomeSummaryFor('plain'), isNull);
    });

    test('a spoken reply lands as a new segment of the same capture', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(outcome: _outcome(CommandState.needsReview)),
      ]);
      final _GrantingRecorder recorder = _GrantingRecorder();
      final RecordingsController controller = build(repo, recorder: recorder);
      await controller.initialize();

      expect(await controller.replyToOutcome('abc'), isTrue);
      expect(controller.isRecording, isTrue);
      expect(controller.appendTargetId, 'abc');
      expect(p.basename(recorder.path!), 'abc-1.m4a');
      await controller.stopRecording();
      await controller.waitForProcessing();

      expect(controller.recordings, hasLength(1));
      final Recording item = controller.recordings.single;
      expect(item.segments, hasLength(2));
      expect(item.segments[1].type, CaptureType.audioRecording);
      expect(item.transcript, '$_secretTranscript\n\nship it after the review');
      expect(
        item.isProcessedByUser,
        isFalse,
        reason: 'the reply is new material for a follow-up handoff',
      );
      expect(
        item.routes.last.outcome!.state,
        CommandState.needsReview,
        reason: 'replying does not rewrite what the agent answered',
      );
    });

    test('an empty reply leaves the parent row untouched', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(outcome: _outcome(CommandState.needsReview)),
      ]);
      final RecordingsController controller = build(
        repo,
        recorder: _GrantingRecorder(take: ''),
      );
      await controller.initialize();
      expect(await controller.replyToOutcome('abc'), isTrue);
      await controller.stopRecording();
      await controller.waitForProcessing();

      expect(controller.error, contains('not persisted'));
      final Recording item = controller.recordings.single;
      expect(item.hasStoredSegments, isFalse);
      expect(item.transcript, _secretTranscript);
      expect(item.isProcessedByUser, isTrue);
      // Whatever reached the index still describes the capture as it was: a
      // fragment that failed verification never touches the parent row.
      for (final Recording saved in repo.saved) {
        expect(saved.hasStoredSegments, isFalse);
        expect(saved.transcript, _secretTranscript);
        expect(saved.isProcessedByUser, isTrue);
      }
    });

    test('a reply is refused for a capture with no outcome', () async {
      // The capture exists, so `startRecording(appendTo:)` alone would start a
      // take: only the outcome guard can refuse these.
      for (final List<RouteRecord> routes in <List<RouteRecord>>[
        const <RouteRecord>[],
        <RouteRecord>[_route(null)],
      ]) {
        final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
          await seedCapture(routes: routes),
        ]);
        final RecordingsController controller = build(
          repo,
          recorder: _GrantingRecorder(),
        );
        await controller.initialize();

        expect(await controller.replyToOutcome('abc'), isFalse);
        expect(controller.isRecording, isFalse);
        expect(controller.hasOutcome('abc'), isFalse);
      }
    });

    test('a reply is refused for an id that does not exist', () async {
      final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
        await seedCapture(),
      ]);
      final RecordingsController controller = build(
        repo,
        recorder: _GrantingRecorder(),
      );
      await controller.initialize();

      expect(await controller.replyToOutcome('missing'), isFalse);
      expect(controller.isRecording, isFalse);
    });

    test('Listen is offered only where a speaker answers available', () async {
      for (final (OutcomeSpeaker speaker, bool expected)
          in <(OutcomeSpeaker, bool)>[
            (const UnavailableOutcomeSpeaker(), false),
            (_RecordingSpeaker(available: false), false),
            (_ThrowingProbeSpeaker(), false),
            (_RecordingSpeaker(), true),
          ]) {
        final _MemoryRepo repo = _MemoryRepo(dir, <Recording>[
          await seedCapture(outcome: _outcome(CommandState.done)),
        ]);
        final RecordingsController controller = build(
          repo,
          outcomeSpeaker: speaker,
        );
        expect(controller.canListenToOutcome, isFalse);
        await controller.initialize();

        expect(controller.canListenToOutcome, expected, reason: '$speaker');
        expect(controller.hasOutcome('abc'), isTrue);
      }
    });
  });
}

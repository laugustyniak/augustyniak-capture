import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

/// The usage sink's scope is ambient (see `UsageSink`): whichever job is open
/// claims every `record()` call made under it. Two paths in the controller open
/// one — the drain's `_processOne` and `retryEnrichment` — so the exclusion
/// between them has to hold in **both** directions, and has to be a wait rather
/// than a refusal: the ENRICH button is ungated, so a refusal is a control that
/// silently does nothing.

/// Keeps what was written, mirroring `test/enrichment_controller_test.dart`'s
/// fake — a fresh copy here since Dart has no cross-file private imports.
class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir);
  final Directory _dir;
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;

  @override
  Future<List<Recording>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _EchoProcessor implements Processor {
  _EchoProcessor();
  int calls = 0;

  @override
  Future<String> process(CaptureSegment segment) async {
    calls++;
    return File(segment.filePath).readAsString();
  }
}

/// Attributes every `record()` call to whichever capture is currently open,
/// the same ambient-state shape `RecordingUsageSink` implements — a call
/// outside any job is dropped rather than misfiled, so a test asserting on
/// [attributedTo] proves attribution rather than merely "something happened".
class _AmbientSink implements UsageSink {
  String? _openCaptureId;
  final List<String> jobLog = <String>[];
  final List<String> attributedTo = <String>[];
  int droppedWithNoOpenJob = 0;

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    _openCaptureId = captureId;
    jobLog.add('begin:$captureId:${stage.name}');
  }

  @override
  void endJob() {
    jobLog.add('end:$_openCaptureId');
    _openCaptureId = null;
  }

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {
    final String? id = _openCaptureId;
    if (id == null) {
      droppedWithNoOpenJob++;
      return;
    }
    attributedTo.add(id);
  }
}

/// Calls the given sink's `record()` as the real `HttpChatEnrichmentService`
/// does, so a test can see which capture an enrichment call's usage event was
/// actually attributed to.
class _RecordingEnrichment implements EnrichmentService {
  _RecordingEnrichment(this.result, this.sink);
  final EnrichmentResult result;
  final UsageSink sink;
  int calls = 0;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 100, outputTokens: 50),
    );
    return result;
  }
}

/// Holds the *first* call open until the test releases it, and records against
/// whichever capture the sink has open at that moment — the same shape as
/// `test/enrichment_controller_test.dart`'s `_GatedEnrichment`, extended with a
/// call counter and the sink hookup this file needs. Later calls pass straight
/// through, so releasing the gate does not have to be repeated per job.
class _GatedRecordingEnrichment implements EnrichmentService {
  _GatedRecordingEnrichment(this.result, this.sink);
  final EnrichmentResult result;
  final UsageSink sink;
  int calls = 0;
  final List<String> textsSeen = <String>[];
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    textsSeen.add(text);
    if (!started.isCompleted) started.complete();
    await release.future;
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 100, outputTokens: 50),
    );
    return result;
  }
}

RecordingsController _controller(
  _FakeRepo repo, {
  required EnrichmentService enrichment,
  required UsageSink usageSink,
  required Processor processor,
}) => RecordingsController(
  repository: repo,
  transcriptionService: const DisabledTranscriptionService(),
  enrichmentService: enrichment,
  usageSink: usageSink,
  processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
    CaptureType.text: processor,
  }),
);

Future<Directory> _tmp() =>
    Directory.systemTemp.createTemp('retry_enrich_usage');

/// Let every microtask and zero-delay continuation the controller has queued
/// run. Used to prove a *negative* — that a path which is supposed to be
/// blocked has not moved — so it deliberately over-pumps rather than waiting
/// for a signal that must never arrive.
Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const EnrichmentResult _verdict = EnrichmentResult(
  title: 'A title',
  category: CaptureCategory.note,
  summary: 'A summary.',
  tags: <String>['tag'],
);

Recording _completedNote(Directory dir, String id, String text) => Recording(
  id: id,
  filePath: '${dir.path}/$id.txt',
  createdAt: DateTime.utc(2026, 8, 9),
  durationMs: 0,
  status: RecordingStatus.completed,
  type: CaptureType.text,
  transcript: text,
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

  test(
    'retryEnrichment opens a usage job, so the event is recorded against '
    'the retried capture rather than dropped for having no open job',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _RecordingEnrichment enrichment = _RecordingEnrichment(
        _verdict,
        sink,
      );
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-a', 'persisted note body'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: enrichment,
        usageSink: sink,
        processor: _EchoProcessor(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.retryEnrichment('cap-a');

      // Before C1, `retryEnrichment` called `_enrich` with no open job, so
      // this event was dropped rather than filed under the capture that was
      // actually retried.
      expect(enrichment.calls, 1);
      expect(sink.droppedWithNoOpenJob, 0);
      expect(sink.attributedTo, <String>['cap-a']);
      expect(sink.jobLog, <String>['begin:cap-a:enrichment', 'end:cap-a']);
    },
  );

  test(
    'a retry started while the drain holds a job waits for it, then records '
    "its event under its own capture — the drain's is untouched",
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated = _GatedRecordingEnrichment(
        _verdict,
        sink,
      );
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-b', 'already has text'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: gated,
        usageSink: sink,
        processor: _EchoProcessor(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      // Drives capture 'a' through the full pipeline (saved -> completed ->
      // enrichment), which opens and holds a usage job for 'a' while its
      // enrichment call is gated open.
      await c.addTextNote('hello from a');
      // `addTextNote` fills `transcript` only once processing completes, so
      // the freshly captured item is identified by not being 'cap-b' rather
      // than by its (not yet set) transcript.
      final String aId = c.recordings
          .firstWhere((Recording r) => r.id != 'cap-b')
          .id;

      // Wait until the drain's enrichment call for 'a' has actually started —
      // i.e. the usage job for 'a' is open — before touching 'cap-b'.
      await gated.started.future;
      expect(sink.jobLog, contains('begin:$aId:enrichment'));

      // While 'a's job is open, a retry on the *other* capture must wait for
      // the scope rather than open a second one underneath it — which is
      // exactly what would misfile 'cap-b's event under 'a'.
      final Future<void> retry = c.retryEnrichment('cap-b');
      await _settle();
      expect(
        gated.calls,
        1,
        reason: "cap-b's retry must not reach the model while a's job is open",
      );
      expect(sink.jobLog, <String>[
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
      ], reason: 'no second scope may be opened under the drain\'s');

      // Release 'a'; the retry that was waiting now takes its turn.
      gated.release.complete();
      await retry;
      await c.waitForProcessing();

      expect(sink.droppedWithNoOpenJob, 0);
      expect(sink.attributedTo, <String>[aId, 'cap-b']);
      expect(sink.jobLog, <String>[
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
        'end:$aId',
        'begin:cap-b:enrichment',
        'end:cap-b',
      ]);
      expect(sink.jobLog, isNot(contains('end:null')));
    },
  );

  test(
    'the drain started while a retry holds a job does not open one on top of '
    'it — the direction `_processingId` alone never covered',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated = _GatedRecordingEnrichment(
        _verdict,
        sink,
      );
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-b', 'already has text'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: gated,
        usageSink: sink,
        processor: _EchoProcessor(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      // The retry goes first this time and is held open inside `_enrich`, so
      // its usage job for 'cap-b' is the one that is live.
      final Future<void> retry = c.retryEnrichment('cap-b');
      await gated.started.future;
      expect(sink.jobLog, <String>['begin:cap-b:enrichment']);

      // Any capture kicks the drain. Reachability is ordinary: ENRICH is a
      // user-tapped button over a seconds-long network call.
      await c.addTextNote('hello from a');
      final String aId = c.recordings
          .firstWhere((Recording r) => r.id != 'cap-b')
          .id;
      await _settle();

      // The drain must be parked on the scope, not running inside 'cap-b's
      // job. Before the fix it opened `begin:$aId:transcription` right here,
      // and 'cap-b's own event was then either dropped or misfiled under 'a'.
      expect(sink.jobLog, <String>['begin:cap-b:enrichment']);
      expect(
        c.recordings.firstWhere((Recording r) => r.id == aId).status,
        RecordingStatus.pendingTranscription,
      );

      gated.release.complete();
      await retry;
      await c.waitForProcessing();

      expect(sink.droppedWithNoOpenJob, 0);
      expect(sink.attributedTo, <String>['cap-b', aId]);
      expect(sink.jobLog, <String>[
        'begin:cap-b:enrichment',
        'end:cap-b',
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
        'end:$aId',
      ]);
      // The trailing `end:null` of the old shape — a retry closing a scope
      // that no longer existed, which with different timing closed the
      // drain's job early and truncated its cost rows.
      expect(sink.jobLog, isNot(contains('end:null')));
    },
  );

  test(
    'a retry that has to wait actually runs afterwards — it is a wait, not a '
    'silent drop on an ungated button',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated = _GatedRecordingEnrichment(
        _verdict,
        sink,
      );
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-b', 'already has text'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: gated,
        usageSink: sink,
        processor: _EchoProcessor(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.addTextNote('hello from a');
      await gated.started.future;

      final Future<void> retry = c.retryEnrichment('cap-b');
      // A second tap while the first is still queued must not buy a second
      // model call for the same capture.
      final Future<void> doubleTap = c.retryEnrichment('cap-b');
      await _settle();
      expect(gated.calls, 1);

      gated.release.complete();
      await retry;
      await doubleTap;
      await c.waitForProcessing();

      // Two enrichment calls in total: the drain's for 'a', and exactly one
      // for the retried 'cap-b' — which did run, and ran on its own text.
      expect(gated.calls, 2);
      expect(gated.textsSeen.last, 'already has text');
      final Recording b = c.recordings.firstWhere(
        (Recording r) => r.id == 'cap-b',
      );
      expect(b.title, 'A title');
      expect(b.summary, 'A summary.');
    },
  );

  test(
    'retryTranscription on a capture whose enrichment retry is running still '
    'queues the job instead of silently doing nothing',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/cap-b.txt').writeAsStringSync('body from disk');
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated = _GatedRecordingEnrichment(
        _verdict,
        sink,
      );
      final _EchoProcessor processor = _EchoProcessor();
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-b', 'already has text'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: gated,
        usageSink: sink,
        processor: processor,
      );
      addTearDown(c.dispose);
      await c.initialize();

      final Future<void> retry = c.retryEnrichment('cap-b');
      await gated.started.future;

      // The enrichment retry no longer claims `_processingId`, so this is not
      // mistaken for "that id is already running in the drain". Before the
      // fix it logged "Retrying processing." and enqueued nothing.
      await c.retryTranscription('cap-b');
      expect(
        c.recordings.firstWhere((Recording r) => r.id == 'cap-b').status,
        RecordingStatus.pendingTranscription,
      );

      gated.release.complete();
      await retry;
      await c.waitForProcessing();

      expect(processor.calls, 1);
      expect(
        c.recordings.firstWhere((Recording r) => r.id == 'cap-b').transcript,
        'body from disk',
      );
    },
  );

  test(
    'three overlapping openers — two retries queued behind the drain — stay '
    'strictly FIFO: no nesting, no end:null, and nobody starves',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated = _GatedRecordingEnrichment(
        _verdict,
        sink,
      );
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          _completedNote(dir, 'cap-b', 'already has text for b'),
          _completedNote(dir, 'cap-c', 'already has text for c'),
        ];
      final RecordingsController c = _controller(
        repo,
        enrichment: gated,
        usageSink: sink,
        processor: _EchoProcessor(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      // First opener: the drain, carrying a freshly captured note through to
      // its enrichment call, which the shared gate holds open.
      await c.addTextNote('hello from a');
      final String aId = c.recordings
          .firstWhere((Recording r) => r.id != 'cap-b' && r.id != 'cap-c')
          .id;
      await gated.started.future;
      expect(sink.jobLog, <String>[
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
      ]);

      // Second and third openers, kicked off back-to-back with **no await
      // between them** — this is the exact window the fix depends on. Each
      // call must publish its own place in the queue *before* it awaits the
      // one ahead of it, so the retry for 'cap-c' has to see the retry for
      // 'cap-b' already registered rather than both reading the drain's
      // future as "ahead" and racing each other once it resolves.
      final Future<void> retryB = c.retryEnrichment('cap-b');
      final Future<void> retryC = c.retryEnrichment('cap-c');
      await _settle();

      // Neither retry may reach the model while 'a's job is still open — both
      // must be queued behind it, never racing it.
      expect(gated.calls, 1);
      expect(sink.jobLog, <String>[
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
      ], reason: 'no second (or third) scope may open under the first');

      // Release the drain; the two retries take their turn, strictly in the
      // order they asked.
      gated.release.complete();
      await retryB;
      await retryC;
      await c.waitForProcessing();

      expect(sink.droppedWithNoOpenJob, 0);
      expect(gated.calls, 3);
      expect(sink.attributedTo, <String>[aId, 'cap-b', 'cap-c']);
      expect(sink.jobLog, <String>[
        'begin:$aId:transcription',
        'end:$aId',
        'begin:$aId:enrichment',
        'end:$aId',
        'begin:cap-b:enrichment',
        'end:cap-b',
        'begin:cap-c:enrichment',
        'end:cap-c',
      ]);
      expect(sink.jobLog, isNot(contains('end:null')));

      // The exact sequence above already proves this, but state it as a
      // standalone invariant too: every `begin:` is matched by its own `end:`
      // before the next `begin:` starts — perfectly balanced, never nesting.
      bool open = false;
      for (final String entry in sink.jobLog) {
        if (entry.startsWith('begin:')) {
          expect(
            open,
            isFalse,
            reason: 'a second job opened on top of one still running: $entry',
          );
          open = true;
        } else {
          expect(
            open,
            isTrue,
            reason: 'a job closed with none open: $entry',
          );
          open = false;
        }
      }
      expect(open, isFalse);
    },
  );
}

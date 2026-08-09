import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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

/// C1: `retryEnrichment` must open a usage job around its `_enrich` call —
/// exactly as `_processOne` does — and must not be able to run while the
/// drain (or another retry) already holds one open, since the sink's scope is
/// ambient state shared by whichever job is open.

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
  const _EchoProcessor();

  @override
  Future<String> process(Recording item) async =>
      File(item.filePath).readAsString();
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

/// Holds the call open until the test releases it, and reports which capture
/// the sink had open at the moment it was called — the same shape as
/// `test/enrichment_controller_test.dart`'s `_GatedEnrichment`, extended with
/// a call counter and the sink hookup this file needs.
class _GatedRecordingEnrichment implements EnrichmentService {
  _GatedRecordingEnrichment(this.result, this.sink);
  final EnrichmentResult result;
  final UsageSink sink;
  int calls = 0;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
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
  Processor processor = const _EchoProcessor(),
}) => RecordingsController(
  repository: repo,
  transcriptionService: const DisabledTranscriptionService(),
  enrichmentService: enrichment,
  usageSink: usageSink,
  processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
    CaptureType.text: processor,
  }),
);

Future<Directory> _tmp() => Directory.systemTemp.createTemp('retry_enrich_usage');

const EnrichmentResult _verdict = EnrichmentResult(
  title: 'A title',
  category: CaptureCategory.note,
  summary: 'A summary.',
  tags: <String>['tag'],
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
      final _RecordingEnrichment enrichment =
          _RecordingEnrichment(_verdict, sink);
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          Recording(
            id: 'cap-a',
            filePath: '${dir.path}/cap-a.txt',
            createdAt: DateTime.utc(2026, 8, 9),
            durationMs: 0,
            status: RecordingStatus.completed,
            type: CaptureType.text,
            transcript: 'persisted note body',
          ),
        ];
      final RecordingsController c =
          _controller(repo, enrichment: enrichment, usageSink: sink);
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
    'a retry cannot open a job while the drain holds one open for a '
    "different capture, so it can never misfile against that capture's job",
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _AmbientSink sink = _AmbientSink();
      final _GatedRecordingEnrichment gated =
          _GatedRecordingEnrichment(_verdict, sink);
      final _FakeRepo repo = _FakeRepo(dir)
        ..saved = <Recording>[
          Recording(
            id: 'cap-b',
            filePath: '${dir.path}/cap-b.txt',
            createdAt: DateTime.utc(2026, 8, 9),
            durationMs: 0,
            status: RecordingStatus.completed,
            type: CaptureType.text,
            transcript: 'already has text',
          ),
        ];
      final RecordingsController c =
          _controller(repo, enrichment: gated, usageSink: sink);
      addTearDown(c.dispose);
      await c.initialize();

      // Drives capture 'a' through the full pipeline (saved -> completed ->
      // enrichment), which opens and holds a usage job for 'a' while its
      // enrichment call is gated open.
      await c.addTextNote('hello from a');
      // `addTextNote` fills `transcript` only once processing completes, so
      // the freshly captured item is identified by not being 'cap-b' rather
      // than by its (not yet set) transcript.
      final String aId =
          c.recordings.firstWhere((Recording r) => r.id != 'cap-b').id;

      // Wait until the drain's enrichment call for 'a' has actually started —
      // i.e. the usage job for 'a' is open — before touching 'cap-b'.
      await gated.started.future;
      expect(sink.jobLog, contains('begin:$aId:enrichment'));

      // While 'a's job is open, a retry on the *other* capture must defer
      // rather than open a second scope underneath it — which is exactly
      // what would misfile 'cap-b's event under 'a'.
      await c.retryEnrichment('cap-b');
      expect(gated.calls, 1, reason: "cap-b's retry must not have reached "
          'the enrichment service while a is open');
      expect(sink.attributedTo, isEmpty, reason: 'nothing has recorded yet');

      // Release 'a' and let the drain finish.
      gated.release.complete();
      await c.waitForProcessing();

      // 'a's event was attributed correctly, and 'cap-b' was never touched by
      // it.
      expect(sink.attributedTo, <String>[aId]);
      expect(
        c.recordings.firstWhere((Recording r) => r.id == 'cap-b').transcript,
        'already has text',
      );

      // Now that the drain is idle, a retry on 'cap-b' proceeds normally and
      // records its own event under its own id — the deferral was a wait, not
      // a permanent lockout.
      await c.retryEnrichment('cap-b');
      expect(gated.calls, 2);
      expect(sink.attributedTo, <String>[aId, 'cap-b']);
    },
  );
}

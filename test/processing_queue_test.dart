import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/processing/domain/processor.dart';
import 'package:audivoa_core/features/processing/domain/processor_registry.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir);
  final Directory _dir;
  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => <Recording>[];
  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _SeededRepo extends _FakeRepo {
  _SeededRepo(super.dir, this.seed);
  final List<Recording> seed;
  @override
  Future<List<Recording>> loadAll() async => seed;
}

/// Counts overlapping saveAll calls to prove the controller serializes writes
/// (recordings.json uses a shared temp file, so overlap would corrupt it).
class _ConcurrencyRepo extends _SeededRepo {
  _ConcurrencyRepo(super.dir, super.seed);
  int active = 0;
  int maxActive = 0;
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(Duration.zero); // simulate async IO
    active--;
  }
}

/// Controllable processor: optionally gates each call on a fresh completer (so
/// a test can hold a job "running"), tracks concurrency, and can fail the first
/// N calls.
class _TestProcessor implements Processor {
  _TestProcessor({this.gated = false, this.failFirst = 0});
  final bool gated;
  final int failFirst;
  final List<Completer<void>> gates = <Completer<void>>[];
  final List<String> processed = <String>[];
  int active = 0;
  int maxActive = 0;
  int calls = 0;

  @override
  Future<String> process(Recording item) async {
    active++;
    if (active > maxActive) maxActive = active;
    calls++;
    final int call = calls;
    try {
      if (gated) {
        final Completer<void> c = Completer<void>();
        gates.add(c);
        await c.future;
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      if (call <= failFirst) throw Exception('boom $call');
      processed.add(item.id);
      return 'ok:${item.id}';
    } finally {
      active--;
    }
  }
}

Future<void> _pump([int n = 6]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Directory> _tmp() => Directory.systemTemp.createTemp('proc_queue');

RecordingsController _controller(_FakeRepo repo, Processor textProcessor) =>
    RecordingsController(
      repository: repo,
      transcriptionService: const DisabledTranscriptionService(),
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: textProcessor,
      }),
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

  test('capture returns without blocking on processing', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(gated: true);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('pierwsza');
    await _pump();

    // Capture lock released and the item is running in the background — not
    // blocked to completion.
    expect(c.isBusy, isFalse);
    expect(c.isProcessing, isTrue);
    expect(c.recordings.single.status, RecordingStatus.transcribing);
    expect(proc.gates.length, 1);

    // A second capture proceeds while the first is still running.
    await c.addTextNote('druga');
    await _pump();
    expect(c.recordings.length, 2);

    // Release both jobs in turn; everything completes.
    proc.gates[0].complete();
    await _pump();
    expect(proc.gates.length, 2); // second job only started after the first
    proc.gates[1].complete();
    await _pump();

    expect(
      c.recordings.every(
        (Recording r) => r.status == RecordingStatus.completed,
      ),
      isTrue,
    );
    expect(c.isProcessing, isFalse);
  });

  test('queue drains one job at a time (never concurrent)', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(gated: true);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('a');
    await c.addTextNote('b');
    await c.addTextNote('c');
    await _pump();

    // Three enqueued, but only one job is in-flight.
    expect(c.pendingProcessingCount, 3);
    expect(proc.gates.length, 1);
    expect(proc.active, 1);

    // Release jobs as they appear.
    while (proc.processed.length < 3) {
      proc.gates.last.complete();
      await _pump();
    }

    expect(proc.maxActive, 1); // never more than one concurrent
    expect(
      c.recordings
          .where((Recording r) => r.status == RecordingStatus.completed)
          .length,
      3,
    );
    expect(c.pendingProcessingCount, 0);
  });

  test('a failing job does not stall the queue', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(failFirst: 1);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('will-fail');
    await c.addTextNote('will-pass');
    await _pump(12);

    final List<RecordingStatus> statuses = c.recordings
        .map((Recording r) => r.status)
        .toList();
    expect(
      statuses.where((RecordingStatus s) => s == RecordingStatus.failed).length,
      1,
    );
    expect(
      statuses
          .where((RecordingStatus s) => s == RecordingStatus.completed)
          .length,
      1,
    );
    expect(c.isProcessing, isFalse);
  });

  test(
    'initialize resumes items left non-terminal by a previous session',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final Recording stuck = Recording(
        id: 's1',
        filePath: '${dir.path}/s1.txt',
        createdAt: DateTime.utc(2026, 7, 25),
        durationMs: 0,
        status: RecordingStatus.transcribing, // interrupted mid-processing
        type: CaptureType.text,
      );
      final RecordingsController c = _controller(
        _SeededRepo(dir, <Recording>[stuck]),
        _TestProcessor(),
      );
      addTearDown(c.dispose);

      await c.initialize();
      await c.waitForProcessing();

      expect(c.recordings.single.status, RecordingStatus.completed);
    },
  );

  test(
    'concurrent index writes are serialized (no shared-temp overlap)',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final Recording seed = Recording(
        id: 'r',
        filePath: '${dir.path}/r.txt',
        createdAt: DateTime.utc(2026, 7, 25),
        durationMs: 0,
        status: RecordingStatus.completed,
        type: CaptureType.text,
      );
      final _ConcurrencyRepo repo = _ConcurrencyRepo(dir, <Recording>[seed]);
      final RecordingsController c = _controller(repo, _TestProcessor());
      addTearDown(c.dispose);
      await c.initialize();
      await c.waitForProcessing();

      // Fire two persist-triggering mutations without awaiting between them.
      final Future<void> f1 = c.toggleProcessed('r');
      final Future<void> f2 = c.toggleProcessed('r');
      await Future.wait(<Future<void>>[f1, f2]);

      expect(repo.maxActive, 1); // never two saveAll in flight at once
    },
  );

  test('re-enqueuing a running item does not process it twice', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(gated: true);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('x');
    await _pump();
    expect(proc.gates.length, 1); // one job running, gated
    final String id = c.recordings.single.id;

    // Retry the item while it is still running — must be a no-op.
    await c.retryTranscription(id);
    await _pump();
    expect(proc.gates.length, 1); // still just one process call

    proc.gates[0].complete();
    await _pump();
    expect(proc.calls, 1); // processed exactly once
  });

  test('retry re-enqueues a failed item and it completes', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(failFirst: 1);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('flaky');
    await _pump(12);
    final Recording failed = c.recordings.single;
    expect(failed.status, RecordingStatus.failed);

    await c.retryTranscription(failed.id); // second call no longer fails
    await _pump(12);
    expect(c.recordings.single.status, RecordingStatus.completed);
  });
}

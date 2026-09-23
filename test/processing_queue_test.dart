import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

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
  Future<String> process(CaptureSegment segment) async {
    // The capture id is the segment file's stem: `<id>.<ext>` for segment 0.
    final String id = p.basenameWithoutExtension(segment.filePath);
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
      processed.add(id);
      return 'ok:\$id';
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

/// Polls until [condition] holds. The drain does real file IO, so how many
/// event-loop turns it takes depends on how busy the machine is — a fixed
/// [_pump] count is only safe for asserting that nothing *more* happened.
/// Throws naming [what] after the backstop, so a hang cannot read as a pass.
Future<void> _until(bool Function() condition, String what) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
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
    await _until(() => proc.gates.length == 1, 'the first job to start');

    // Capture lock released and the item is running in the background — not
    // blocked to completion.
    expect(c.isBusy, isFalse);
    expect(c.isProcessing, isTrue);
    expect(c.recordings.single.status, RecordingStatus.transcribing);
    expect(proc.gates.length, 1);

    // A second capture proceeds while the first is still running.
    await c.addTextNote('druga');
    await _until(() => c.recordings.length == 2, 'the second capture');
    expect(c.recordings.length, 2);

    // Release both jobs in turn; everything completes.
    proc.gates[0].complete();
    await _until(() => proc.gates.length == 2, 'the second job to start');
    expect(proc.gates.length, 2); // second job only started after the first
    proc.gates[1].complete();
    await _until(() => !c.isProcessing, 'the queue to drain');

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
    await _until(() => proc.gates.length == 1, 'the first job to start');

    // Three enqueued, but only one job is in-flight.
    expect(c.pendingProcessingCount, 3);
    expect(proc.gates.length, 1);
    expect(proc.active, 1);

    // Release jobs as they appear.
    while (proc.processed.length < 3) {
      final int done = proc.processed.length;
      proc.gates.last.complete();
      await _until(
        () =>
            proc.processed.length > done &&
            (proc.processed.length == 3 || proc.gates.length > done + 1),
        'the next job',
      );
    }
    await _until(() => !c.isProcessing, 'the queue to drain');

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
    await _until(
      () => !c.isProcessing && c.pendingProcessingCount == 0,
      'both jobs to finish',
    );

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
      File('${dir.path}/s1.txt').writeAsStringSync('stuck fragment');
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
    'initialize processes a capture that has a source and no text',
    () async {
      // The state an orphan recovery and a salvaged timeout both leave behind:
      // `saved`, no transcript, and nothing in the app that would ever pick it
      // up. Before this sweep covered it, the take came back from the dead and
      // then sat in the queue permanently untranscribed.
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/orphan.txt').writeAsStringSync('recovered fragment');
      final Recording recovered = Recording(
        id: 'orphan',
        filePath: '${dir.path}/orphan.txt',
        createdAt: DateTime.utc(2026, 7, 25),
        durationMs: 0,
        status: RecordingStatus.saved,
        type: CaptureType.text,
      );
      final RecordingsController c = _controller(
        _SeededRepo(dir, <Recording>[recovered]),
        _TestProcessor(),
      );
      addTearDown(c.dispose);

      await c.initialize();
      await c.waitForProcessing();

      expect(c.recordings.single.status, RecordingStatus.completed);
    },
  );

  test(
    'initialize leaves a saved capture that already holds its text alone',
    () async {
      // The other half of `awaitsProcessing`: widening the sweep must not turn
      // start-up into a re-run of work that is already done — the drain skips
      // segments that hold text, and this is what pins that.
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final Recording done = Recording(
        id: 'done',
        filePath: '${dir.path}/done.txt',
        createdAt: DateTime.utc(2026, 7, 25),
        durationMs: 0,
        status: RecordingStatus.saved,
        type: CaptureType.text,
        transcript: 'already read out',
      );
      final _TestProcessor processor = _TestProcessor();
      final RecordingsController c = _controller(
        _SeededRepo(dir, <Recording>[done]),
        processor,
      );
      addTearDown(c.dispose);

      await c.initialize();
      await c.waitForProcessing();

      expect(processor.processed, isEmpty);
      expect(c.recordings.single.transcript, 'already read out');
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
    await _until(() => proc.gates.length == 1, 'the job to start');
    expect(proc.gates.length, 1); // one job running, gated
    final String id = c.recordings.single.id;

    // Retry the item while it is still running — must be a no-op.
    await c.retryTranscription(id);
    await _pump();
    expect(proc.gates.length, 1); // still just one process call

    proc.gates[0].complete();
    await _until(() => !c.isProcessing, 'the job to finish');
    expect(proc.calls, 1); // processed exactly once
  });

  test('retry re-enqueues a failed item and it completes', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _TestProcessor proc = _TestProcessor(failFirst: 1);
    final RecordingsController c = _controller(_FakeRepo(dir), proc);
    addTearDown(c.dispose);

    await c.addTextNote('flaky');
    await _until(
      () => c.recordings.single.status == RecordingStatus.failed,
      'the first attempt to fail',
    );
    final Recording failed = c.recordings.single;
    expect(failed.status, RecordingStatus.failed);

    await c.retryTranscription(failed.id); // second call no longer fails
    await _until(
      () => c.recordings.single.status == RecordingStatus.completed,
      'the retry to complete',
    );
    expect(c.recordings.single.status, RecordingStatus.completed);
  });

  test(
    'waitForProcessing reports outstanding work instead of claiming success',
    () async {
      // The defect this pins was silent: the wait gave up after a fixed number
      // of microtask turns and returned as though the queue had drained, so on
      // a machine busy enough that the real IO had not landed yet, every
      // assertion after the call read pre-completion state. That is what made
      // `vault_mirror_test` report `Bad state: No element` on a CI runner and
      // pass on every idle one — the note was not missing, it had simply not
      // been written, and nothing said so.
      //
      // A backstop is still wanted so a genuine hang ends. It just has to be
      // impossible to mistake for the work having finished.
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _TestProcessor proc = _TestProcessor(gated: true);
      final RecordingsController c = _controller(_FakeRepo(dir), proc);
      addTearDown(c.dispose);

      await c.addTextNote('held open');
      await _until(() => proc.gates.length == 1, 'the job to start');

      await expectLater(
        c.waitForProcessing(timeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(contains('timed out'), contains('draining=true')),
          ),
        ),
      );

      // Released so the gated job does not outlive the test.
      for (final Completer<void> gate in proc.gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await c.waitForProcessing();
    },
  );

  test(
    'resumeInterruptedProcessing finds stuck captures, re-enqueues without duplication, and drains to completion',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/p1.txt').writeAsStringSync('pending fragment');
      File('${dir.path}/t1.txt').writeAsStringSync('transcribing fragment');
      File('${dir.path}/a1.txt').writeAsStringSync('awaiting fragment');
      File('${dir.path}/c1.txt').writeAsStringSync('already done');
      final Recording pending = Recording(
        id: 'p1',
        filePath: '${dir.path}/p1.txt',
        createdAt: DateTime.utc(2026, 7, 25, 10),
        durationMs: 0,
        status: RecordingStatus.pendingTranscription,
        type: CaptureType.text,
      );
      final Recording transcribing = Recording(
        id: 't1',
        filePath: '${dir.path}/t1.txt',
        createdAt: DateTime.utc(2026, 7, 25, 11),
        durationMs: 0,
        status: RecordingStatus.transcribing,
        type: CaptureType.text,
      );
      final Recording awaits = Recording(
        id: 'a1',
        filePath: '${dir.path}/a1.txt',
        createdAt: DateTime.utc(2026, 7, 25, 12),
        durationMs: 0,
        status: RecordingStatus.saved,
        type: CaptureType.text,
      );
      final Recording completed = Recording(
        id: 'c1',
        filePath: '${dir.path}/c1.txt',
        createdAt: DateTime.utc(2026, 7, 25, 9),
        durationMs: 0,
        status: RecordingStatus.completed,
        type: CaptureType.text,
        transcript: 'already done',
      );

      final _TestProcessor proc = _TestProcessor();
      final RecordingsController c = _controller(
        _SeededRepo(dir, <Recording>[pending, transcribing, awaits, completed]),
        proc,
      );
      addTearDown(c.dispose);

      await c.initialize();
      await c.waitForProcessing();

      expect(proc.processed, containsAll(<String>['p1', 't1', 'a1']));
      expect(proc.processed.contains('c1'), isFalse);
      expect(
        c.recordings.every((Recording r) => r.status == RecordingStatus.completed),
        isTrue,
      );

      // Calling resumeInterruptedProcessing again when all are completed does nothing
      proc.processed.clear();
      await c.resumeInterruptedProcessing();
      await c.waitForProcessing();
      expect(proc.processed, isEmpty);
    },
  );

  test(
    'resumeInterruptedProcessing does not duplicate in-flight or queued items',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _TestProcessor proc = _TestProcessor(gated: true);
      final RecordingsController c = _controller(_FakeRepo(dir), proc);
      addTearDown(c.dispose);

      await c.addTextNote('running-item');
      await _until(() => proc.gates.length == 1, 'the job to start');
      expect(proc.gates.length, 1);
      expect(c.isProcessing, isTrue);

      // Trigger resume while the item is already running
      await c.resumeInterruptedProcessing();
      await _pump();

      // Should still be only 1 running job, no duplicates queued
      expect(proc.gates.length, 1);
      expect(c.pendingProcessingCount, 1);

      proc.gates[0].complete();
      await c.waitForProcessing();
      expect(proc.calls, 1);
      expect(c.recordings.single.status, RecordingStatus.completed);
    },
  );

  test(
    'resumeInterruptedProcessing leaves a recording whose source is not on '
    'this device untouched — finding 2',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      // What a sync pull leaves behind before its media has synced (slice 4
      // of #187): status travels verbatim from the row that pushed it, but
      // the file behind it is not on this device — a bare name never
      // resolved against the recordings directory, exactly like
      // `SyncRowCodec.recordingFromRow` emits for a fresh install.
      final Recording pulled = Recording(
        id: 'pulled-1',
        filePath: 'pulled-1.m4a',
        createdAt: DateTime.utc(2026, 7, 25, 10),
        durationMs: 0,
        status: RecordingStatus.pendingTranscription,
        type: CaptureType.text,
      );
      final _TestProcessor proc = _TestProcessor();
      final RecordingsController c = _controller(
        _SeededRepo(dir, <Recording>[pulled]),
        proc,
      );
      addTearDown(c.dispose);

      // initialize() runs resumeInterruptedProcessing() itself.
      await c.initialize();

      expect(
        c.recordings.single.status,
        RecordingStatus.pendingTranscription,
        reason: 'the gate refuses without changing status either way',
      );
      expect(proc.processed, isEmpty);
      expect(c.isProcessing, isFalse, reason: 'the drain was never kicked');

      // Calling it again directly (RETRY's own funnel) is just as inert.
      await c.resumeInterruptedProcessing();
      expect(proc.processed, isEmpty);
      expect(c.isProcessing, isFalse);
    },
  );
}

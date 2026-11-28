import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/live_transcription.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// Keeps the index in memory and notes, at every save, what was on disk then,
/// which is how the persist-before-process order is observed.
class _Repo extends RecordingsRepository {
  _Repo(this._dir, [this.seed = const <Recording>[]]);
  final Directory _dir;
  final List<Recording> seed;
  final List<({RecordingStatus status, int bytes})> saves =
      <({RecordingStatus status, int bytes})>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => seed;
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    for (final Recording r in recordings) {
      final File f = File(r.filePath);
      saves.add((
        status: r.status,
        bytes: f.existsSync() ? f.lengthSync() : -1,
      ));
    }
  }
}

class _Recorder implements AudioRecorder {
  final StreamController<Uint8List> pcm = StreamController<Uint8List>();
  int startCalls = 0;
  int streamCalls = 0;
  Object? streamError;
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCalls++;
    File(path).writeAsStringSync('m4a bytes', flush: true);
    this.path = path;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    streamCalls++;
    if (streamError != null) throw streamError!;
    return pcm.stream;
  }

  @override
  Future<String?> stop() async {
    if (pcm.hasListener && !pcm.isClosed) await pcm.close();
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _Session implements LiveTranscriptionSession {
  final StreamController<LiveTranscript> _updates =
      StreamController<LiveTranscript>.broadcast();
  final Completer<String> result = Completer<String>();
  Object? addAudioError;
  int chunks = 0;
  bool finishCalled = false;
  bool cancelled = false;

  @override
  Stream<LiveTranscript> get updates => _updates.stream;
  void emit(LiveTranscript t) => _updates.add(t);

  @override
  void addAudio(Uint8List pcm16le) {
    chunks++;
    if (addAudioError != null) throw addAudioError!;
  }

  @override
  Future<String> finish() {
    finishCalled = true;
    return result.future;
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

class _Service implements LiveTranscriptionService {
  _Service(this.session);
  final _Session session;
  int starts = 0;

  @override
  bool get isAvailable => true;
  @override
  int get sampleRate => 16000;
  @override
  LiveTranscriptionSession start() {
    starts++;
    return session;
  }
}

class _BatchProcessor implements Processor {
  int calls = 0;
  @override
  Future<String> process(CaptureSegment segment) async {
    calls++;
    return 'batch text';
  }
}

class _Enrichment implements EnrichmentService {
  int calls = 0;
  String? lastText;
  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    lastText = text;
    return const EnrichmentResult(
      title: 'Titled',
      category: CaptureCategory.capture,
    );
  }
}

Uint8List _pcm(int n) => Uint8List.fromList(List<int>.filled(n, 1));

Future<void> _until(bool Function() ok) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!ok()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      throw TimeoutException('condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

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

  late Directory dir;
  late _Repo repo;
  late _Recorder recorder;
  late _Session session;
  late _Service service;
  late _BatchProcessor batch;
  late _Enrichment enrichment;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('live-dictation');
    repo = _Repo(dir);
    recorder = _Recorder();
    session = _Session();
    service = _Service(session);
    batch = _BatchProcessor();
    enrichment = _Enrichment();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  RecordingsController build({
    LiveTranscriptionService? live,
    Duration liveResultTimeout = const Duration(seconds: 5),
    _Repo? repository,
  }) {
    return RecordingsController(
      repository: repository ?? repo,
      transcriptionService: const DisabledTranscriptionService(),
      recorder: recorder,
      enrichmentService: enrichment,
      liveTranscription: live == null ? null : () => live,
      liveResultTimeout: liveResultTimeout,
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.audioRecording: batch,
      }),
    );
  }

  /// Records a short live take and stops it, leaving processing to the caller.
  Future<void> recordLiveTake(RecordingsController c) async {
    await c.initialize();
    await c.startRecording();
    expect(c.isRecording, isTrue);
    recorder.pcm.add(_pcm(3200));
    await _until(() => session.chunks == 1);
    await c.stopRecording();
  }

  group('a live take', () {
    test(
      'persists the WAV before any status change and uses the live text',
      () async {
        final RecordingsController c = build(live: service);
        await recordLiveTake(c);
        session.result.complete('live text');
        await c.waitForProcessing();

        expect(repo.saves.first.status, RecordingStatus.saved);
        expect(
          repo.saves.first.bytes,
          greaterThan(44),
          reason: 'the WAV is on disk and holds audio before the first save',
        );
        final Recording item = c.recordings.single;
        expect(p.extension(item.filePath), '.wav');
        expect(item.status, RecordingStatus.completed);
        expect(item.transcript, 'live text');
        expect(batch.calls, 0, reason: 'the processor is skipped');
        expect(enrichment.calls, 1);
        expect(enrichment.lastText, 'live text');
        expect(session.finishCalled, isTrue);
        c.dispose();
      },
    );

    test('empty live text falls back to the batch processor', () async {
      final RecordingsController c = build(live: service);
      await recordLiveTake(c);
      session.result.complete('   ');
      await c.waitForProcessing();

      expect(batch.calls, 1);
      expect(c.recordings.single.transcript, 'batch text');
      expect(c.recordings.single.status, RecordingStatus.completed);
      c.dispose();
    });

    test('an incomplete finish falls back and keeps the recording', () async {
      final RecordingsController c = build(live: service);
      await recordLiveTake(c);
      session.result.completeError(const LiveTranscriptionIncomplete());
      await c.waitForProcessing();

      expect(batch.calls, 1);
      final Recording item = c.recordings.single;
      expect(item.transcript, 'batch text');
      expect(File(item.filePath).existsSync(), isTrue);
      c.dispose();
    });

    test('any other finish error falls back too', () async {
      final RecordingsController c = build(live: service);
      await recordLiveTake(c);
      session.result.completeError(StateError('boom'));
      await c.waitForProcessing();

      expect(batch.calls, 1);
      expect(c.recordings.single.transcript, 'batch text');
      c.dispose();
    });

    test('a finish that never answers times out into the batch path', () async {
      final RecordingsController c = build(
        live: service,
        liveResultTimeout: const Duration(milliseconds: 50),
      );
      await recordLiveTake(c);
      // `session.result` is never completed.
      await c.waitForProcessing();

      expect(batch.calls, 1);
      expect(c.recordings.single.status, RecordingStatus.completed);
      expect(c.recordings.single.transcript, 'batch text');
      c.dispose();
    });

    test('a session that throws on addAudio does not stop the take', () async {
      session.addAudioError = StateError('socket gone');
      final RecordingsController c = build(live: service);
      await c.initialize();
      await c.startRecording();
      recorder.pcm.add(_pcm(3200));
      recorder.pcm.add(_pcm(3200));
      await _until(() => session.chunks == 2);
      await c.stopRecording();
      session.result.completeError(const LiveTranscriptionIncomplete());
      await c.waitForProcessing();

      expect(c.error, isNull);
      final Recording item = c.recordings.single;
      expect(File(item.filePath).lengthSync(), 44 + 6400);
      expect(item.transcript, 'batch text');
      c.dispose();
    });

    test('the ticker follows the session and clears after stop', () async {
      final RecordingsController c = build(live: service);
      await c.initialize();
      expect(c.liveTicker.value, isNull);
      await c.startRecording();
      expect(c.liveTicker.value, isNotNull);
      session.emit(const LiveTranscript(committed: 'a', partial: 'b'));
      await _until(() => c.liveTicker.value?.partial == 'b');
      session.emit(const LiveTranscript(committed: 'a', failed: true));
      await _until(() => c.liveTicker.value?.failed == true);
      recorder.pcm.add(_pcm(64));
      await _until(() => session.chunks == 1);
      await c.stopRecording();
      expect(c.liveTicker.value, isNull);
      session.result.complete('a');
      await c.waitForProcessing();
      c.dispose();
    });

    test('a take with no audio is not saved and cancels the session', () async {
      final RecordingsController c = build(live: service);
      await c.initialize();
      await c.startRecording();
      await c.stopRecording();

      expect(c.recordings, isEmpty);
      expect(c.error, isNotNull);
      expect(session.cancelled, isTrue);
      expect(session.finishCalled, isFalse);
      expect(dir.listSync().whereType<File>(), isEmpty);
      c.dispose();
    });

    test(
      'discard deletes the WAV, cancels the session, saves nothing',
      () async {
        final RecordingsController c = build(live: service);
        await c.initialize();
        await c.startRecording();
        recorder.pcm.add(_pcm(3200));
        await _until(() => session.chunks == 1);
        await c.discardRecording();

        expect(c.recordings, isEmpty);
        expect(session.cancelled, isTrue);
        expect(dir.listSync().whereType<File>(), isEmpty);
        expect(c.liveTicker.value, isNull);
        c.dispose();
      },
    );

    test('a start failure removes the file and cancels the session', () async {
      recorder.streamError = StateError('mic busy');
      final RecordingsController c = build(live: service);
      await c.initialize();
      await c.startRecording();

      expect(c.isRecording, isFalse);
      expect(c.error, contains('mic busy'));
      expect(session.cancelled, isTrue);
      expect(dir.listSync().whereType<File>(), isEmpty);
      expect(c.liveTicker.value, isNull);
      c.dispose();
    });

    test(
      'cancelling processing while the live result is awaited wins, even with a late live text',
      () async {
        final RecordingsController c = build(live: service);
        await recordLiveTake(c);
        final String id = c.recordings.single.id;
        await _until(
          () => c.recordings.single.status == RecordingStatus.transcribing,
        );
        await c.cancelProcessing(id);
        session.result.complete('late text');
        await c.waitForProcessing();

        final Recording item = c.recordings.single;
        expect(item.status, RecordingStatus.failed);
        expect(item.error, 'Cancelled by user');
        expect(item.transcript, isNull);
        expect(batch.calls, 0);
        expect(enrichment.calls, 0);
        c.dispose();
      },
    );

    test(
      'cancelling processing while the live result is awaited wins, even with a failed live result',
      () async {
        final RecordingsController c = build(live: service);
        await recordLiveTake(c);
        final String id = c.recordings.single.id;
        await _until(
          () => c.recordings.single.status == RecordingStatus.transcribing,
        );
        await c.cancelProcessing(id);
        session.result.completeError(const LiveTranscriptionIncomplete());
        await c.waitForProcessing();

        final Recording item = c.recordings.single;
        expect(item.status, RecordingStatus.failed);
        expect(item.error, 'Cancelled by user');
        expect(item.transcript, isNull);
        expect(batch.calls, 0);
        expect(enrichment.calls, 0);
        c.dispose();
      },
    );

    test(
      'deleting the capture while the live result is awaited is safe',
      () async {
        final RecordingsController c = build(live: service);
        await recordLiveTake(c);
        final String id = c.recordings.single.id;
        await _until(
          () => c.recordings.single.status == RecordingStatus.transcribing,
        );
        await c.deleteRecording(id);
        session.result.complete('late text');
        await c.waitForProcessing();

        expect(c.recordings, isEmpty);
        expect(enrichment.calls, 0);
        c.dispose();
      },
    );
  });

  group('without live dictation', () {
    test('the default resolver keeps the m4a path', () async {
      final RecordingsController c = build();
      await c.initialize();
      await c.startRecording();
      await c.stopRecording();
      await c.waitForProcessing();

      expect(recorder.startCalls, 1);
      expect(recorder.streamCalls, 0);
      expect(p.extension(c.recordings.single.filePath), '.m4a');
      expect(c.liveTicker.value, isNull);
      expect(batch.calls, 1);
      c.dispose();
    });

    test('appending to a capture uses start(), never startStream()', () async {
      final File first = File(p.join(dir.path, 'abc.m4a'))
        ..writeAsStringSync('first');
      final Recording seed = Recording(
        id: 'abc',
        filePath: first.path,
        createdAt: DateTime.utc(2026, 8, 28),
        durationMs: 1000,
        sizeBytes: 5,
        status: RecordingStatus.completed,
        type: CaptureType.audioRecording,
        transcript: 'first',
      );
      final RecordingsController c = build(
        live: service,
        repository: _Repo(dir, <Recording>[seed]),
      );
      await c.initialize();
      await c.startRecording(appendTo: 'abc');
      await c.stopRecording();
      await c.waitForProcessing();

      expect(recorder.startCalls, 1);
      expect(recorder.streamCalls, 0);
      expect(service.starts, 0);
      expect(c.recordings.single.segments, hasLength(2));
      expect(p.extension(c.recordings.single.segments[1].filePath), '.m4a');
      c.dispose();
    });
  });
}

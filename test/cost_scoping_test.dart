import 'dart:io';

import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records the job scope rather than the usage, so the assertions read as the
/// sequence of jobs the pipeline opened.
class _ScopeSink implements UsageSink {
  final List<String> log = <String>[];
  final List<double?> fallbacks = <double?>[];

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    log.add('begin:$captureId:${stage.name}');
    fallbacks.add(fallbackAudioSeconds);
  }

  @override
  void endJob() => log.add('end');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {}
}

class _ThrowingSink implements UsageSink {
  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) =>
      throw StateError('boom');

  @override
  void endJob() => throw StateError('boom');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) =>
      throw StateError('boom');
}

Recording _seed({
  required String id,
  required CaptureType type,
  required int durationMs,
}) {
  return Recording(
    id: id,
    filePath: '/nonexistent/$id.bin',
    createdAt: DateTime.utc(2026, 8, 9),
    durationMs: durationMs,
    status: RecordingStatus.saved,
    type: type,
  );
}

void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('cost-scoping');
  });

  tearDown(() {
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
  });

  test('a text note opens a transcription job, then an enrichment one', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
    );

    await controller.addTextNote('a note');
    await controller.waitForProcessing();

    final String id = controller.recordings.single.id;
    expect(sink.log, <String>[
      'begin:$id:transcription',
      'end',
      'begin:$id:enrichment',
      'end',
    ]);
  });

  test('an image capture opens an ocr job, not a transcription one', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(id: 'img-1', type: CaptureType.image, durationMs: 0),
      ],
    );

    await controller.retryTranscription('img-1');
    await controller.waitForProcessing();

    expect(sink.log.first, 'begin:img-1:ocr');
  });

  test('a mic capture passes its own duration as the audio fallback', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(
          id: 'mic-1',
          type: CaptureType.audioRecording,
          durationMs: 90000,
        ),
      ],
    );

    await controller.retryTranscription('mic-1');
    await controller.waitForProcessing();

    expect(sink.fallbacks.first, closeTo(90, 1e-9));
  });

  test('an upload with durationMs 0 passes no fallback at all', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(id: 'up-1', type: CaptureType.audioUpload, durationMs: 0),
      ],
    );

    await controller.retryTranscription('up-1');
    await controller.waitForProcessing();

    // Zero is not a duration — pricing it as one would bill the upload at $0.
    expect(sink.fallbacks.first, isNull);
  });

  test('a processor that throws still closes its job', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(
          id: 'bad-1',
          type: CaptureType.audioRecording,
          durationMs: 1000,
        ),
      ],
    );

    // No transcription profile and no file on disk, so the processor throws.
    await controller.retryTranscription('bad-1');
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(
      sink.log.where((String entry) => entry == 'end').length,
      sink.log.where((String entry) => entry.startsWith('begin')).length,
    );
  });

  test('a sink that throws never costs the capture', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: _ThrowingSink(),
    );

    await controller.addTextNote('survives');
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(controller.recordings.single.transcript, 'survives');
  });
}

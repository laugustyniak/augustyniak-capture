import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/commitment.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo extends RecordingsRepository {
  _Repo(this._dir);
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

class _Echo implements Processor {
  const _Echo();
  @override
  Future<String> process(CaptureSegment segment) async =>
      File(segment.filePath).readAsString();
}

class _Enrichment implements EnrichmentService {
  _Enrichment(this.result);
  EnrichmentResult result;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async => result;
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

  // A Wednesday, months before the test runs: a due date computed from the
  // wall clock instead of from this would land somewhere else entirely.
  final DateTime createdAt = DateTime(2026, 3, 4, 18, 15);

  late Directory dir;
  late _Repo repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('commitments_ctrl');
    repo = _Repo(dir)
      ..saved = <Recording>[
        Recording(
          id: 'c1',
          filePath: '${dir.path}/c1.txt',
          createdAt: createdAt,
          durationMs: 0,
          status: RecordingStatus.completed,
          type: CaptureType.text,
          transcript: 'I will send the offer by Friday and call Marek tomorrow',
        ),
      ];
  });
  tearDown(() => dir.delete(recursive: true));

  RecordingsController controllerWith(_Enrichment enrichment) =>
      RecordingsController(
        repository: repo,
        transcriptionService: const DisabledTranscriptionService(),
        enrichmentService: enrichment,
        enrichmentContextSource: const EmptyEnrichmentContextSource(),
        processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
          CaptureType.text: const _Echo(),
        }),
      );

  test('enrichment stores commitments with due dates from createdAt', () async {
    final _Enrichment enrichment = _Enrichment(
      const EnrichmentResult(
        commitments: <CommitmentDraft>[
          CommitmentDraft(text: 'Send the offer', due: 'Friday'),
          CommitmentDraft(text: 'Call Marek', due: 'tomorrow', who: 'me'),
        ],
      ),
    );
    final RecordingsController c = controllerWith(enrichment);
    addTearDown(c.dispose);
    await c.initialize();

    await c.retryEnrichment('c1');

    final List<Commitment> stored = repo.saved.single.commitments!;
    expect(stored[0].due, DateTime(2026, 3, 6));
    expect(stored[1].due, DateTime(2026, 3, 5));
    expect(stored[1].who, 'me');
  });

  test(
    'a reply without commitments never marks the item as extracted',
    () async {
      final RecordingsController c = controllerWith(
        _Enrichment(const EnrichmentResult(title: 'x')),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.retryEnrichment('c1');

      expect(c.recordings.single.commitments, isNull);
    },
  );

  test('re-enrichment keeps the done and dismissed state', () async {
    final _Enrichment enrichment = _Enrichment(
      const EnrichmentResult(
        commitments: <CommitmentDraft>[
          CommitmentDraft(text: 'Send the offer', due: 'Friday'),
          CommitmentDraft(text: 'Call Marek', due: 'tomorrow'),
        ],
      ),
    );
    final RecordingsController c = controllerWith(enrichment);
    addTearDown(c.dispose);
    await c.initialize();
    await c.retryEnrichment('c1');

    await c.setCommitmentState('c1', 'send the offer', CommitmentState.done);
    await c.setCommitmentState('c1', 'Call Marek', CommitmentState.dismissed);
    expect(
      repo.saved.single.commitments!.map((Commitment x) => x.state),
      <CommitmentState>[CommitmentState.done, CommitmentState.dismissed],
    );

    await c.retryEnrichment('c1');

    final List<Commitment> after = repo.saved.single.commitments!;
    expect(after, hasLength(2));
    expect(
      after.firstWhere((Commitment x) => x.key == 'send the offer').state,
      CommitmentState.done,
    );
    expect(
      after.firstWhere((Commitment x) => x.key == 'call marek').state,
      CommitmentState.dismissed,
    );
  });

  test('setCommitmentState can reopen, and ignores an unknown key', () async {
    final RecordingsController c = controllerWith(
      _Enrichment(
        const EnrichmentResult(
          commitments: <CommitmentDraft>[CommitmentDraft(text: 'A')],
        ),
      ),
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.retryEnrichment('c1');

    await c.setCommitmentState('c1', 'a', CommitmentState.done);
    await c.setCommitmentState('c1', 'a', CommitmentState.open);
    await c.setCommitmentState('c1', 'missing', CommitmentState.done);
    expect(c.recordings.single.commitments!.single.state, CommitmentState.open);
  });
}

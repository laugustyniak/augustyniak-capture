import 'dart:io';

import 'package:audivoa_core/features/enrichment/domain/enrichment_result.dart';
import 'package:audivoa_core/features/enrichment/domain/enrichment_service.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/data/revisions_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_category.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/domain/recording_tag.dart';
import 'package:audivoa_core/features/recordings/domain/recording_revision.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._items);
  List<Recording> _items;
  @override
  Future<List<Recording>> loadAll() async => _items;
  @override
  Future<void> saveAll(List<Recording> recordings) async =>
      _items = List<Recording>.of(recordings);
}

/// In-memory stand-in for the JSONL file. Keeps the append-only semantics so a
/// test can prove nothing is ever rewritten.
class _FakeRevisions extends RevisionsRepository {
  final List<RecordingRevision> appended = <RecordingRevision>[];
  Map<String, List<RecordingRevision>> seed =
      <String, List<RecordingRevision>>{};

  @override
  Future<Map<String, List<RecordingRevision>>> load() async => seed;

  @override
  Future<void> append(List<RecordingRevision> revisions) async =>
      appended.addAll(revisions);
}

/// Returns the text it is told to. Enrichment only ever runs after a processor
/// succeeds, so a test that wants to observe the second stage has to let the
/// first one through.
class _StubTranscription implements TranscriptionService {
  _StubTranscription(this.text);
  final String text;
  @override
  Future<String> transcribe(File file) async => text;
}

class _StubEnrichment implements EnrichmentService {
  _StubEnrichment(this.result);
  final EnrichmentResult result;
  @override
  Future<EnrichmentResult> enrich(String text) async => result;
}

Recording _seed({
  String? title,
  String? transcript,
  CaptureCategory? category,
  String? summary,
  List<String> tags = const <String>[],
}) => Recording(
  id: 'r1',
  filePath: '/tmp/r1.m4a',
  createdAt: DateTime.utc(2026, 8, 4),
  durationMs: 1000,
  status: RecordingStatus.completed,
  title: title,
  transcript: transcript,
  category: category,
  summary: summary,
  tags: <RecordingTag>[
    for (final String value in tags)
      RecordingTag(value: value, source: RecordingTagSource.human),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannel(name),
          (MethodCall call) async => null,
        );
  }

  Future<(RecordingsController, _FakeRevisions)> build(
    Recording seed, {
    EnrichmentService? enrichment,
    TranscriptionService? transcription,
  }) async {
    final _FakeRevisions revisions = _FakeRevisions();
    final RecordingsController controller = RecordingsController(
      repository: _FakeRepo(<Recording>[seed]),
      transcriptionService:
          transcription ?? const DisabledTranscriptionService(),
      enrichmentService: enrichment ?? const DisabledEnrichmentService(),
      revisionsRepository: revisions,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    return (controller, revisions);
  }

  group('what is recorded', () {
    test(
      'a hand edit that overwrites a title is attributed to the user',
      () async {
        final (RecordingsController c, _FakeRevisions revisions) = await build(
          _seed(title: 'Old name'),
        );

        await c.setTitle('r1', 'New name');

        final RecordingRevision entry = revisions.appended.single;
        expect(entry.field, 'title');
        expect(entry.from, 'Old name');
        expect(entry.to, 'New name');
        expect(entry.source, RevisionSource.user);
        expect(c.revisionsFor('r1'), hasLength(1));
      },
    );

    test(
      'filling a blank field records nothing — nothing was overwritten',
      () async {
        final (RecordingsController c, _FakeRevisions revisions) = await build(
          _seed(),
        );

        await c.setTitle('r1', 'First ever name');
        await c.editTranscript('r1', 'the first transcript');

        expect(revisions.appended, isEmpty);
        expect(c.revisionsFor('r1'), isEmpty);
      },
    );

    test('a re-run that replaces the transcript keeps the old text', () async {
      final (RecordingsController c, _FakeRevisions revisions) = await build(
        _seed(transcript: 'the original words'),
      );

      await c.editTranscript('r1', 'a corrected version');

      final RecordingRevision entry = revisions.appended.single;
      expect(entry.field, 'transcript');
      expect(
        entry.from,
        'the original words',
        reason: 'the overwritten text is the only copy left anywhere',
      );
    });

    test('clearing a category records the removal', () async {
      final (RecordingsController c, _FakeRevisions revisions) = await build(
        _seed(category: CaptureCategory.task),
      );

      await c.setCategory('r1', null);

      final RecordingRevision entry = revisions.appended.single;
      expect(entry.field, 'category');
      expect(entry.from, 'task');
      expect(entry.to, isNull);
    });

    test('a status transition is not history', () async {
      final (RecordingsController c, _FakeRevisions revisions) = await build(
        _seed(transcript: 'text'),
      );

      await c.retryTranscription('r1');
      await c.waitForProcessing();

      expect(
        revisions.appended.map((RecordingRevision r) => r.field),
        isNot(contains('status')),
      );
    });
  });

  group('enrichment', () {
    test(
      'a refreshed summary is attributed to the model and keeps the old one',
      () async {
        final (RecordingsController c, _FakeRevisions revisions) = await build(
          _seed(
            title: 'Named by hand',
            transcript: 'some text',
            summary: 'the first summary',
            tags: <String>['old'],
          ),
          // Same text back, so the only revisions in play come from enrichment.
          transcription: _StubTranscription('some text'),
          enrichment: _StubEnrichment(
            const EnrichmentResult(
              title: 'Model name',
              category: CaptureCategory.idea,
              summary: 'a fresh summary',
              tags: <String>['new'],
            ),
          ),
        );

        await c.retryTranscription('r1');
        await c.waitForProcessing();

        final RecordingRevision summary = revisions.appended.firstWhere(
          (RecordingRevision r) => r.field == 'summary',
        );
        expect(summary.from, 'the first summary');
        expect(summary.to, 'a fresh summary');
        expect(summary.source, RevisionSource.enrichment);

        // The fill-only rule still holds: a hand-typed title is not touched, so
        // there is no title revision to record either.
        expect(c.recordings.single.title, 'Named by hand');
        expect(
          revisions.appended.where((RecordingRevision r) => r.field == 'title'),
          isEmpty,
        );
      },
    );
  });

  group('durability', () {
    test('a failed append still shows in this session', () async {
      final _FailingRevisions revisions = _FailingRevisions();
      final RecordingsController c = RecordingsController(
        repository: _FakeRepo(<Recording>[_seed(title: 'Old')]),
        transcriptionService: const DisabledTranscriptionService(),
        revisionsRepository: revisions,
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', 'New');

      // The write blew up; the capture still went through and the entry is
      // visible for the rest of the session.
      expect(c.recordings.single.title, 'New');
      expect(c.revisionsFor('r1'), hasLength(1));
    });

    test('history loaded from disk is available immediately', () async {
      final _FakeRevisions revisions = _FakeRevisions()
        ..seed = <String, List<RecordingRevision>>{
          'r1': <RecordingRevision>[
            RecordingRevision(
              recordingId: 'r1',
              at: DateTime.utc(2026, 8, 3),
              field: 'title',
              from: 'Yesterday',
              to: 'Today',
              source: RevisionSource.enrichment,
            ),
          ],
        };
      final RecordingsController c = RecordingsController(
        repository: _FakeRepo(<Recording>[_seed()]),
        transcriptionService: const DisabledTranscriptionService(),
        revisionsRepository: revisions,
      );
      addTearDown(c.dispose);
      await c.initialize();

      expect(c.revisionsFor('r1').single.from, 'Yesterday');
    });

    test('no revisions repository means the feature is simply off', () async {
      final RecordingsController c = RecordingsController(
        repository: _FakeRepo(<Recording>[_seed(title: 'Old')]),
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(c.dispose);
      await c.initialize();

      await c.setTitle('r1', 'New');
      expect(c.revisionsFor('r1'), isEmpty);
      expect(c.recordings.single.title, 'New');
    });
  });

  group('RecordingRevision', () {
    test('round-trips through JSON', () {
      final RecordingRevision original = RecordingRevision(
        recordingId: 'r1',
        at: DateTime.utc(2026, 8, 4, 12, 30),
        field: 'title',
        from: 'a',
        to: null,
        source: RevisionSource.user,
      );
      final RecordingRevision restored = RecordingRevision.fromJson(
        original.toJson(),
      );

      expect(restored.recordingId, 'r1');
      expect(restored.at, original.at);
      expect(restored.from, 'a');
      expect(restored.to, isNull);
      expect(restored.source, RevisionSource.user);
    });

    test('an unknown source degrades instead of throwing', () {
      final RecordingRevision restored =
          RecordingRevision.fromJson(<String, dynamic>{
            'recordingId': 'r1',
            'at': '2026-08-04T12:00:00.000Z',
            'field': 'title',
            'from': 'a',
            'to': 'b',
            'source': 'something-a-newer-build-wrote',
          });
      expect(restored.source, RevisionSource.processor);
    });

    test('an oversized value is truncated and says so', () {
      final String long = 'x' * (RecordingRevision.maxValueLength + 500);
      final String? truncated = RecordingRevision.truncate(long);
      expect(truncated!.length, lessThan(long.length));
      expect(truncated, contains('500 more characters'));
    });
  });
}

class _FailingRevisions extends RevisionsRepository {
  @override
  Future<Map<String, List<RecordingRevision>>> load() async =>
      <String, List<RecordingRevision>>{};

  @override
  Future<void> append(List<RecordingRevision> revisions) async =>
      throw FileSystemException('disk full');
}

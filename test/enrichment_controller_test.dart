import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/enrichment/domain/enrichment_result.dart';
import 'package:audivoa_core/features/enrichment/domain/enrichment_service.dart';
import 'package:audivoa_core/features/processing/domain/processor.dart';
import 'package:audivoa_core/features/processing/domain/processor_registry.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_category.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

/// Keeps what was written, so a test can assert that a correction survived the
/// round trip to disk rather than only living in memory.
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

/// Returns whatever the note body was, so the pipeline behaves like the real
/// text passthrough processor.
class _EchoProcessor implements Processor {
  const _EchoProcessor();

  @override
  Future<String> process(Recording item) async =>
      File(item.filePath).readAsString();
}

class _FakeEnrichment implements EnrichmentService {
  _FakeEnrichment(this.result);
  final EnrichmentResult result;
  int calls = 0;
  String? lastText;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    calls++;
    lastText = text;
    return result;
  }
}

/// Holds the call open until the test lets go, so "the model is reading it
/// right now" is a state the test can stand in rather than a moment it has to
/// catch. A delay would work too, and would race the scheduler for it.
class _GatedEnrichment implements EnrichmentService {
  _GatedEnrichment(this.result);
  final EnrichmentResult result;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<EnrichmentResult> enrich(String text) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return result;
  }
}

class _ThrowingEnrichment implements EnrichmentService {
  int calls = 0;

  @override
  Future<EnrichmentResult> enrich(String text) async {
    calls++;
    throw StateError('boom');
  }
}

/// Processor whose output is blank, to prove enrichment is never asked to
/// classify nothing.
class _BlankProcessor implements Processor {
  const _BlankProcessor();

  @override
  Future<String> process(Recording item) async => '   ';
}

RecordingsController _controller(
  _FakeRepo repo, {
  EnrichmentService? enrichment,
  Processor processor = const _EchoProcessor(),
}) => RecordingsController(
  repository: repo,
  transcriptionService: const DisabledTranscriptionService(),
  enrichmentService: enrichment ?? const DisabledEnrichmentService(),
  processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
    CaptureType.text: processor,
  }),
);

Future<Directory> _tmp() => Directory.systemTemp.createTemp('enrich_ctrl');

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

  const EnrichmentResult verdict = EnrichmentResult(
    title: 'Notatka o kliencie',
    category: CaptureCategory.meetingNote,
    summary: 'Ustalenia ze spotkania.',
    tags: <String>['klient', 'oferta'],
  );

  test('fills title, category, summary and tags on a completed item', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    final Recording item = c.recordings.single;
    expect(item.status, RecordingStatus.completed);
    expect(item.title, 'Notatka o kliencie');
    expect(item.category, CaptureCategory.meetingNote);
    expect(item.summary, 'Ustalenia ze spotkania.');
    expect(item.tags, <String>['klient', 'oferta']);
    expect(enrichment.lastText, 'spotkanie z klientem');
  });

  test('never overwrites a user-set title', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    final String id = c.recordings.single.id;
    await c.setTitle(id, 'Moja nazwa');
    await c.retryTranscription(id);
    await c.waitForProcessing();

    expect(enrichment.calls, 2); // it ran again
    expect(c.recordings.single.title, 'Moja nazwa'); // and left the title alone
    expect(c.recordings.single.category, CaptureCategory.meetingNote);
  });

  test('never overwrites a user-corrected category', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    final String id = c.recordings.single.id;
    await c.setCategory(id, CaptureCategory.idea);
    await c.retryTranscription(id);
    await c.waitForProcessing();

    // The correction is what an export will read, so a re-run must not undo it.
    expect(c.recordings.single.category, CaptureCategory.idea);
    // Derived summary is refreshed. Existing tags are retained because tags
    // are user-editable and a retry must not undo a manual assignment.
    expect(c.recordings.single.summary, 'Ustalenia ze spotkania.');
    expect(c.recordings.single.tags, <String>['klient', 'oferta']);
  });

  test('never overwrites user-set tags', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    final String id = c.recordings.single.id;
    await c.setTags(id, <String>[' Project:Acme ', 'LEGAL', 'legal', '']);
    await c.retryTranscription(id);
    await c.waitForProcessing();

    expect(c.recordings.single.tags, <String>['project:acme', 'legal']);
  });

  test('a cleared category is filled again by the next run', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: _FakeEnrichment(verdict),
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    final String id = c.recordings.single.id;
    // Clearing is how the user asks for a re-classification.
    await c.setCategory(id, null);
    await c.retryTranscription(id);
    await c.waitForProcessing();

    expect(c.recordings.single.category, CaptureCategory.meetingNote);
  });

  test('a throwing enrichment service leaves the item completed', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _ThrowingEnrichment enrichment = _ThrowingEnrichment();
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
    );
    addTearDown(c.dispose);

    await c.addTextNote('treść');
    await c.waitForProcessing();

    final Recording item = c.recordings.single;
    expect(enrichment.calls, 1);
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, 'treść');
    expect(item.error, isNull); // a failed enrichment is not an item failure
    expect(item.category, isNull);
  });

  test('the disabled service is a silent no-op', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final RecordingsController c = _controller(_FakeRepo(dir));
    addTearDown(c.dispose);

    await c.addTextNote('treść');
    await c.waitForProcessing();

    expect(c.recordings.single.status, RecordingStatus.completed);
    expect(c.recordings.single.category, isNull);
    expect(c.error, isNull);
  });

  test('a blank processor output is not sent for enrichment', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
      processor: const _BlankProcessor(),
    );
    addTearDown(c.dispose);

    await c.addTextNote('cokolwiek');
    await c.waitForProcessing();

    expect(enrichment.calls, 0);
  });

  test('a swapped service only affects the next job', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _ThrowingEnrichment first = _ThrowingEnrichment();
    final _FakeEnrichment second = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: first,
    );
    addTearDown(c.dispose);

    await c.addTextNote('pierwsza');
    await c.waitForProcessing();
    c.enrichmentService = second;
    await c.addTextNote('druga');
    await c.waitForProcessing();

    expect(first.calls, 1);
    expect(second.calls, 1);
    // Newest first: the item captured after the swap is the enriched one.
    expect(c.recordings.first.category, CaptureCategory.meetingNote);
    expect(c.recordings.last.category, isNull);
  });

  test(
    'the item is flagged as enriching only while the call is open',
    () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _GatedEnrichment enrichment = _GatedEnrichment(verdict);
      final RecordingsController c = _controller(
        _FakeRepo(dir),
        enrichment: enrichment,
      );
      addTearDown(c.dispose);

      await c.addTextNote('spotkanie z klientem');
      await enrichment.started.future;

      final Recording midway = c.recordings.single;
      expect(c.isEnriching(midway.id), isTrue);
      // The flag is a view fact laid over an item that is already whole: the
      // status, the text and the file are all durable before enrichment starts.
      expect(midway.status, RecordingStatus.completed);
      expect(midway.transcript, 'spotkanie z klientem');

      enrichment.release.complete();
      await c.waitForProcessing();

      expect(c.isEnriching(midway.id), isFalse);
      expect(c.recordings.single.title, 'Notatka o kliencie');
    },
  );

  test('a failing enrichment still clears the flag', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: _ThrowingEnrichment(),
    );
    addTearDown(c.dispose);

    await c.addTextNote('treść');
    await c.waitForProcessing();

    // A stuck flag would leave a card animating for the rest of the session.
    expect(c.isEnriching(c.recordings.single.id), isFalse);
  });

  test('the disabled service leaves nothing flagged', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final RecordingsController c = _controller(_FakeRepo(dir));
    addTearDown(c.dispose);

    await c.addTextNote('treść');
    await c.waitForProcessing();

    expect(c.isEnriching(c.recordings.single.id), isFalse);
  });

  test('setCategory overwrites the model verdict and persists', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeRepo repo = _FakeRepo(dir);
    final RecordingsController c = _controller(
      repo,
      enrichment: _FakeEnrichment(verdict),
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie');
    await c.waitForProcessing();
    await c.setCategory(c.recordings.single.id, CaptureCategory.task);

    expect(c.recordings.single.category, CaptureCategory.task);
    expect(repo.saved.single.category, CaptureCategory.task);
  });

  test('setCategory(null) clears the category', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: _FakeEnrichment(verdict),
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie');
    await c.waitForProcessing();
    await c.setCategory(c.recordings.single.id, null);

    expect(c.recordings.single.category, isNull);
  });
}

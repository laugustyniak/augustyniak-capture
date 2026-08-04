import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/enrichment/domain/enrichment_context.dart';
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
  EnrichmentResult result;
  int calls = 0;
  String? lastText;
  EnrichmentContext? lastContext;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    lastText = text;
    lastContext = context;
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
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return result;
  }
}

class _ThrowingEnrichment implements EnrichmentService {
  int calls = 0;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
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

/// Answers a fixed context and records which project it was asked about, so a
/// test can prove the item's own project — not the one active right now —
/// decided what the model was told.
class _FakeContextSource implements EnrichmentContextSource {
  _FakeContextSource(this.context);
  final EnrichmentContext context;
  final List<String?> requestedFor = <String?>[];

  @override
  Future<EnrichmentContext> contextFor(String? projectId) async {
    requestedFor.add(projectId);
    return context;
  }
}

class _ThrowingContextSource implements EnrichmentContextSource {
  @override
  Future<EnrichmentContext> contextFor(String? projectId) async =>
      throw StateError('repo is gone');
}

RecordingsController _controller(
  _FakeRepo repo, {
  EnrichmentService? enrichment,
  EnrichmentContextSource? contextSource,
  Processor processor = const _EchoProcessor(),
}) => RecordingsController(
  repository: repo,
  transcriptionService: const DisabledTranscriptionService(),
  enrichmentService: enrichment ?? const DisabledEnrichmentService(),
  enrichmentContextSource:
      contextSource ?? const EmptyEnrichmentContextSource(),
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

  test('the context reaches the model, resolved from the item project',
      () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final _FakeContextSource source = _FakeContextSource(
      const EnrichmentContext(
        profile: 'I collect specs.',
        project: 'Offline-first recorder.',
        projectSource: 'CLAUDE.md',
      ),
    );
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
      contextSource: source,
    );
    addTearDown(c.dispose);

    c.activeProjectId = 'p1';
    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    expect(source.requestedFor, <String?>['p1']);
    expect(enrichment.lastContext?.profile, 'I collect specs.');
    expect(enrichment.lastContext?.projectSource, 'CLAUDE.md');
  });

  test('an unresolvable context costs a better title, never the enrichment',
      () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final RecordingsController c = _controller(
      _FakeRepo(dir),
      enrichment: enrichment,
      contextSource: _ThrowingContextSource(),
    );
    addTearDown(c.dispose);

    await c.addTextNote('spotkanie z klientem');
    await c.waitForProcessing();

    // The item is still enriched, with an empty context rather than none at all.
    expect(enrichment.calls, 1);
    expect(enrichment.lastContext?.isEmpty, isTrue);
    expect(c.recordings.single.title, 'Notatka o kliencie');
    expect(c.recordings.single.status, RecordingStatus.completed);
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
    // `summary` has no editor, so it is pure derived output and refreshes.
    expect(c.recordings.single.summary, 'Ustalenia ze spotkania.');
    // Tags are fill-only, and this item already has some, so they stand.
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

    // A tag set by hand is the whole list: `_enrich` fills `tags` only when
    // they are empty, so a re-run leaves a corrected set alone rather than
    // appending its own suggestions beside it.
    expect(c.recordings.single.tags, <String>['project:acme', 'legal']);
  });

  test('a retry leaves an existing tag list alone', () async {
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
    await c.setTags(id, <String>['legal']);

    enrichment.result = const EnrichmentResult(
      title: 'ignored because already filled',
      category: CaptureCategory.task,
      summary: 'New summary',
      tags: <String>['follow-up'],
    );
    await c.retryTranscription(id);
    await c.waitForProcessing();

    expect(c.recordings.single.tags, <String>['legal']);
    // The field that genuinely has no editor still refreshes.
    expect(c.recordings.single.summary, 'New summary');
  });

  test('clearing the tags asks the next run for a fresh set', () async {
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

    await c.setTags(id, <String>[]);
    expect(c.recordings.single.tags, isEmpty);

    enrichment.result = const EnrichmentResult(
      title: 'ignored because already filled',
      category: CaptureCategory.task,
      summary: 'New summary',
      tags: <String>['follow-up', 'Follow-Up', ' '],
    );
    await c.retryTranscription(id);
    await c.waitForProcessing();

    // Clearing the field is how you ask for it to be filled again.
    expect(c.recordings.single.tags, <String>['follow-up']);
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

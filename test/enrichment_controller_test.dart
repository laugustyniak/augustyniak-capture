import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/transcript_cleaner.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/stale_rank.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

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
  Future<String> process(CaptureSegment segment) async =>
      File(segment.filePath).readAsString();
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
  Future<String> process(CaptureSegment segment) async => '   ';
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

  test('re-runs enrichment from persisted text without reprocessing', () async {
    final Directory dir = await _tmp();
    addTearDown(() => dir.delete(recursive: true));
    final _FakeEnrichment enrichment = _FakeEnrichment(verdict);
    final _FakeRepo repo = _FakeRepo(dir)
      ..saved = <Recording>[
        Recording(
          id: 'existing',
          filePath: '${dir.path}/existing.txt',
          createdAt: DateTime(2026),
          durationMs: 0,
          status: RecordingStatus.completed,
          type: CaptureType.text,
          transcript: 'persisted note body',
          title: 'Existing title',
          category: CaptureCategory.task,
          summary: 'Old summary',
          tags: <String>['kept'],
        ),
      ];
    final RecordingsController c = _controller(repo, enrichment: enrichment);
    addTearDown(c.dispose);
    await c.initialize();

    await c.retryEnrichment('existing');

    expect(enrichment.calls, 1);
    expect(enrichment.lastText, 'persisted note body');
    expect(c.recordings.single.title, 'Existing title');
    expect(c.recordings.single.category, CaptureCategory.task);
    expect(c.recordings.single.summary, 'Ustalenia ze spotkania.');
    expect(c.recordings.single.tags, <String>['kept']);
    expect(c.recordings.single.status, RecordingStatus.completed);
  });

  test(
    'the context reaches the model, resolved from the item project',
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

      // The stamp from the active project is an auto guess (#284), so its own
      // repo context is withheld; a project the user picked is looked up.
      expect(source.requestedFor, <String?>[null]);
      await c.setProject(c.recordings.single.id, 'p1');
      await c.retryEnrichment(c.recordings.single.id);
      expect(source.requestedFor, <String?>[null, 'p1']);
      expect(enrichment.lastContext?.profile, 'I collect specs.');
      expect(enrichment.lastContext?.projectSource, 'CLAUDE.md');
    },
  );

  test(
    'an unresolvable context costs a better title, never the enrichment',
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
    },
  );

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
    await c.retryEnrichment(id);
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
    await c.retryEnrichment(id);
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
    await c.retryEnrichment(id);
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
    await c.retryEnrichment(id);
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
    await c.retryEnrichment(id);
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
    await c.retryEnrichment(id);
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

  group('priority', () {
    const EnrichmentResult ranked = EnrichmentResult(
      title: 'Notatka o kliencie',
      category: CaptureCategory.task,
      priority: CapturePriority.p1,
      priorityReason: 'Serves the Q4 goal.',
    );

    test('enrichment ranks an unranked item', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FakeRepo repo = _FakeRepo(dir);
      final RecordingsController c = _controller(
        repo,
        enrichment: _FakeEnrichment(ranked),
      );
      addTearDown(c.dispose);

      await c.addTextNote('zadzwonić do klienta');
      await c.waitForProcessing();

      expect(c.recordings.single.priority, CapturePriority.p1);
      expect(c.recordings.single.priorityReason, 'Serves the Q4 goal.');
      expect(repo.saved.single.priority, CapturePriority.p1);
    });

    test('a re-run never overwrites a user-set priority', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FakeEnrichment enrichment = _FakeEnrichment(ranked);
      final RecordingsController c = _controller(
        _FakeRepo(dir),
        enrichment: enrichment,
      );
      addTearDown(c.dispose);

      await c.addTextNote('zadzwonić do klienta');
      await c.waitForProcessing();
      final String id = c.recordings.single.id;

      await c.setPriority(id, CapturePriority.p3);
      // The model's reason argued for p1; it explains nothing about p3.
      expect(c.recordings.single.priorityReason, isNull);

      await c.retryEnrichment(id);
      await c.waitForProcessing();

      expect(enrichment.calls, 2);
      expect(c.recordings.single.priority, CapturePriority.p3);
      expect(c.recordings.single.priorityReason, isNull);
    });

    test('a cleared priority is ranked again by the next run', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FakeEnrichment enrichment = _FakeEnrichment(ranked);
      final RecordingsController c = _controller(
        _FakeRepo(dir),
        enrichment: enrichment,
      );
      addTearDown(c.dispose);

      await c.addTextNote('zadzwonić do klienta');
      await c.waitForProcessing();
      final String id = c.recordings.single.id;

      await c.setPriority(id, null);
      expect(c.recordings.single.priority, isNull);

      enrichment.result = const EnrichmentResult(
        priority: CapturePriority.p0,
        priorityReason: 'Client deadline tomorrow.',
      );
      await c.retryEnrichment(id);
      await c.waitForProcessing();

      expect(c.recordings.single.priority, CapturePriority.p0);
      expect(c.recordings.single.priorityReason, 'Client deadline tomorrow.');
    });

    test('a rank records which soul it was judged against', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      const EnrichmentContext soul = EnrichmentContext(
        profile: 'Goal: ship the beta.',
      );
      final RecordingsController c = _controller(
        _FakeRepo(dir),
        enrichment: _FakeEnrichment(ranked),
        contextSource: _FakeContextSource(soul),
      );
      addTearDown(c.dispose);

      await c.addTextNote('zadzwonić do klienta');
      await c.waitForProcessing();
      final String id = c.recordings.single.id;

      expect(c.recordings.single.priorityBasis, soul.profileBasis);
      expect(c.recordings.single.priorityBasis, isNotNull);

      // A hand-set rank was judged against no profile.
      await c.setPriority(id, CapturePriority.p2);
      expect(c.recordings.single.priorityBasis, isNull);
    });

    test('an unranked verdict leaves the item unranked', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = _controller(
        _FakeRepo(dir),
        enrichment: _FakeEnrichment(verdict),
      );
      addTearDown(c.dispose);

      await c.addTextNote('spotkanie');
      await c.waitForProcessing();

      expect(c.recordings.single.priority, isNull);
      expect(c.recordings.single.priorityReason, isNull);
    });
  });

  group('rerankStale', () {
    const EnrichmentContext soul = EnrichmentContext(profile: 'Goal: beta.');
    const EnrichmentResult reranked = EnrichmentResult(
      title: 'A NEW TITLE',
      category: CaptureCategory.idea,
      summary: 'A new summary.',
      tags: <String>['new'],
      priority: CapturePriority.p0,
      priorityReason: 'p0 rule: the beta is due.',
    );

    Recording seeded(
      Directory dir,
      String id, {
      CapturePriority? priority,
      String? basis,
      bool done = false,
    }) => Recording(
      id: id,
      filePath: '${dir.path}/$id.txt',
      createdAt: DateTime(2026, 10, 6),
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: 'body of $id',
      title: 'Title $id',
      category: CaptureCategory.task,
      summary: 'Summary $id',
      tags: const <String>['kept'],
      priority: priority,
      priorityReason: priority == null ? null : 'old reason',
      priorityBasis: basis,
      isProcessedByUser: done,
    );

    Future<RecordingsController> controllerWith(
      Directory dir,
      List<Recording> seed,
      EnrichmentService enrichment,
    ) async {
      final _FakeRepo repo = _FakeRepo(dir)..saved = seed;
      final RecordingsController c = _controller(
        repo,
        enrichment: enrichment,
        contextSource: _FakeContextSource(soul),
      );
      addTearDown(c.dispose);
      await c.initialize();
      return c;
    }

    Recording byId(RecordingsController c, String id) =>
        c.recordings.firstWhere((Recording r) => r.id == id);

    test('re-ranks only stale desk items, and only their priority', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FakeEnrichment enrichment = _FakeEnrichment(reranked);
      final RecordingsController c = await controllerWith(dir, <Recording>[
        seeded(dir, 'stale', priority: CapturePriority.p3, basis: 'old00000'),
        seeded(dir, 'hand', priority: CapturePriority.p1),
        seeded(dir, 'current',
            priority: CapturePriority.p2, basis: soul.profileBasis),
        seeded(dir, 'unranked'),
        seeded(dir, 'off',
            priority: CapturePriority.p3, basis: 'old00000', done: true),
      ], enrichment);

      expect(await c.staleRankCount(), 1);
      final RerankSummary summary = await c.rerankStale();

      expect(summary.reranked, 1);
      expect(enrichment.calls, 1);
      final Recording stale = byId(c, 'stale');
      expect(stale.priority, CapturePriority.p0);
      expect(stale.priorityReason, 'p0 rule: the beta is due.');
      expect(stale.priorityBasis, soul.profileBasis);
      // A ranking pass, not a re-enrichment.
      expect(stale.title, 'Title stale');
      expect(stale.category, CaptureCategory.task);
      expect(stale.summary, 'Summary stale');
      expect(stale.tags, <String>['kept']);
      // Everything else untouched.
      expect(byId(c, 'hand').priority, CapturePriority.p1);
      expect(byId(c, 'current').priority, CapturePriority.p2);
      expect(byId(c, 'unranked').priority, isNull);
      expect(byId(c, 'off').priority, CapturePriority.p3);
      expect(await c.staleRankCount(), 0);
      expect(c.rerankProgress, isNull);
    });

    test('a rank set by hand mid-pass wins', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _GatedEnrichment enrichment = _GatedEnrichment(reranked);
      final RecordingsController c = await controllerWith(dir, <Recording>[
        seeded(dir, 'stale', priority: CapturePriority.p3, basis: 'old00000'),
      ], enrichment);

      final Future<RerankSummary> pass = c.rerankStale();
      await enrichment.started.future;
      expect(c.rerankProgress?.total, 1);
      await c.setPriority('stale', CapturePriority.p2);
      enrichment.release.complete();
      final RerankSummary summary = await pass;

      expect(summary.reranked, 0);
      expect(summary.skipped, 1);
      expect(byId(c, 'stale').priority, CapturePriority.p2);
      expect(byId(c, 'stale').priorityBasis, isNull);
    });

    test('one failure is logged and the pass moves on', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FlakyEnrichment enrichment = _FlakyEnrichment(reranked);
      final RecordingsController c = await controllerWith(dir, <Recording>[
        seeded(dir, 'a', priority: CapturePriority.p3, basis: 'old00000'),
        seeded(dir, 'b', priority: CapturePriority.p3, basis: 'old00000'),
      ], enrichment);

      final RerankSummary summary = await c.rerankStale();

      expect(summary.failed, 1);
      expect(summary.reranked, 1);
      expect(c.rerankProgress, isNull);
      expect(await c.staleRankCount(), 1); // the failed one is still stale
    });

    test('cancel stops the pass after the item in flight', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _GatedEnrichment enrichment = _GatedEnrichment(reranked);
      final RecordingsController c = await controllerWith(dir, <Recording>[
        seeded(dir, 'a', priority: CapturePriority.p3, basis: 'old00000'),
        seeded(dir, 'b', priority: CapturePriority.p3, basis: 'old00000'),
      ], enrichment);

      final Future<RerankSummary> pass = c.rerankStale();
      await enrichment.started.future;
      c.cancelRerank();
      enrichment.release.complete();
      final RerankSummary summary = await pass;

      expect(summary.cancelled, isTrue);
      expect(summary.reranked, 1);
      expect(await c.staleRankCount(), 1);
    });
  });

  group('transcript clean-up', () {
    const String raw = 'eee so we need to uh call the client';
    const String clean = 'So we need to call the client.';

    Recording spoken(
      Directory dir,
      String id, {
      CaptureType type = CaptureType.audioRecording,
    }) => Recording(
      id: id,
      filePath: '${dir.path}/$id.m4a',
      createdAt: DateTime(2026, 10, 7),
      durationMs: 1000,
      status: RecordingStatus.completed,
      type: type,
      transcript: raw,
    );

    Future<RecordingsController> withCleaner(
      Directory dir,
      List<Recording> seed,
      TranscriptCleaner cleaner,
    ) async {
      final _FakeRepo repo = _FakeRepo(dir)..saved = seed;
      final RecordingsController c = _controller(repo)
        ..transcriptCleaner = cleaner;
      addTearDown(c.dispose);
      await c.initialize();
      return c;
    }

    test('a proposal never writes the transcript', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], _FakeCleaner(clean));

      await c.proposeCleanup('a');

      expect(c.recordings.single.transcript, raw);
      expect(c.recordings.single.cleanup?.text, clean);
      expect(c.recordings.single.cleanup?.matches(raw), isTrue);
      expect(c.isCleaning('a'), isFalse);
    });

    test('accept writes the proposal and clears it', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], _FakeCleaner(clean));
      await c.proposeCleanup('a');

      expect(await c.acceptCleanup('a'), isTrue);

      expect(c.recordings.single.transcript, clean);
      expect(c.recordings.single.cleanup, isNull);
    });

    test('reject drops the proposal and leaves the transcript alone', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], _FakeCleaner(clean));
      await c.proposeCleanup('a');

      await c.rejectCleanup('a');

      expect(c.recordings.single.cleanup, isNull);
      expect(c.recordings.single.transcript, raw);
    });

    test('a stale proposal cannot be accepted', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], _FakeCleaner(clean));
      await c.proposeCleanup('a');
      await c.editTranscript('a', '$raw and one more thing');

      expect(await c.acceptCleanup('a'), isFalse);
      expect(c.recordings.single.transcript, '$raw and one more thing');
    });

    test('an edit while the call runs gets no proposal for old text', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _GatedCleaner cleaner = _GatedCleaner(clean);
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], cleaner);

      final Future<void> pending = c.proposeCleanup('a');
      await cleaner.started.future;
      expect(c.isCleaning('a'), isTrue);
      await c.editTranscript('a', 'edited by hand');
      cleaner.release.complete();
      await pending;

      expect(c.recordings.single.cleanup, isNull);
      expect(c.recordings.single.transcript, 'edited by hand');
    });

    test('a failure is swallowed and proposes nothing', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a'),
      ], const DisabledTranscriptCleaner());

      await c.proposeCleanup('a');

      expect(c.recordings.single.cleanup, isNull);
      expect(c.recordings.single.status, RecordingStatus.completed);
      expect(c.cleanupError('a'), contains('Configure'));
    });

    for (final bool auto in <bool>[true, false]) {
      test('a dictation that finishes processing is proposed only when '
          'auto clean-up is ${auto ? 'on' : 'off'}', () async {
        final Directory dir = await _tmp();
        addTearDown(() => dir.delete(recursive: true));
        await File('${dir.path}/a.m4a').writeAsString(raw);
        final _FakeCleaner cleaner = _FakeCleaner(clean);
        final RecordingsController c = RecordingsController(
          repository: _FakeRepo(dir)
            ..saved = <Recording>[
              Recording(
                id: 'a',
                filePath: '${dir.path}/a.m4a',
                createdAt: DateTime(2026, 10, 7),
                durationMs: 1000,
                status: RecordingStatus.failed,
              ),
            ],
          transcriptionService: const DisabledTranscriptionService(),
          enrichmentService: const DisabledEnrichmentService(),
          processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
            CaptureType.audioRecording: const _EchoProcessor(),
          }),
        )
          ..transcriptCleaner = cleaner
          ..autoCleanup = auto;
        addTearDown(c.dispose);
        await c.initialize();

        await c.retryTranscription('a');
        await c.waitForProcessing();

        expect(c.recordings.single.status, RecordingStatus.completed);
        expect(cleaner.calls, auto ? 1 : 0);
        expect(c.recordings.single.cleanup?.text, auto ? clean : null);
        expect(c.recordings.single.transcript, raw);
      });
    }

    test('a note typed by hand is never cleaned', () async {
      final Directory dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final _FakeCleaner cleaner = _FakeCleaner(clean);
      final RecordingsController c = await withCleaner(dir, <Recording>[
        spoken(dir, 'a', type: CaptureType.text),
      ], cleaner);

      await c.proposeCleanup('a');

      expect(cleaner.calls, 0);
      expect(c.recordings.single.cleanup, isNull);
    });
  });
}

/// Throws on the first call only, so a pass sees one failure and one success.
class _FlakyEnrichment implements EnrichmentService {
  _FlakyEnrichment(this.result);
  final EnrichmentResult result;
  int calls = 0;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    if (calls == 1) throw StateError('boom');
    return result;
  }
}

class _FakeCleaner implements TranscriptCleaner {
  _FakeCleaner(this.result);
  final String result;
  int calls = 0;

  @override
  Future<String> cleanUp(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    return result;
  }
}

class _GatedCleaner implements TranscriptCleaner {
  _GatedCleaner(this.result);
  final String result;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<String> cleanUp(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return result;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';

void main() {
  test('recording JSON round-trip preserves AI and user processing state', () {
    final DateTime processedAt = DateTime.utc(2026, 7, 21, 8, 30);
    final Recording original = Recording(
      id: 'abc',
      filePath: '/tmp/abc.m4a',
      createdAt: DateTime.utc(2026, 7, 20),
      durationMs: 1500,
      status: RecordingStatus.completed,
      transcript: 'Test',
      title: 'Spotkanie z klientem',
      isProcessedByUser: true,
      processedAt: processedAt,
    );

    final Recording restored = Recording.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.status, RecordingStatus.completed);
    expect(restored.transcript, 'Test');
    expect(restored.title, 'Spotkanie z klientem');
    expect(restored.isProcessedByUser, isTrue);
    expect(restored.processedAt, processedAt);
  });

  test('sizeBytes round-trips, and legacy rows default it to zero', () {
    final Recording original = Recording(
      id: 'sized',
      filePath: '/tmp/sized.m4a',
      createdAt: DateTime.utc(2026, 7, 20),
      durationMs: 1500,
      sizeBytes: 7_123_456,
      status: RecordingStatus.completed,
    );

    expect(Recording.fromJson(original.toJson()).sizeBytes, 7_123_456);
    // Survives a status transition — the size is measured once, at capture.
    expect(
      original.copyWith(status: RecordingStatus.failed).sizeBytes,
      7_123_456,
    );

    final Recording legacy = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': DateTime.utc(2026, 7, 20).toIso8601String(),
      'durationMs': 900,
      'status': RecordingStatus.saved.name,
    });
    expect(legacy.sizeBytes, 0);
  });

  test('copyWith edits transcript and title, and clears the title', () {
    final Recording original = Recording(
      id: 'x',
      filePath: '/tmp/x.m4a',
      createdAt: DateTime.utc(2026, 7, 20),
      durationMs: 100,
      status: RecordingStatus.completed,
      transcript: 'old',
      title: 'old title',
    );

    final Recording edited = original.copyWith(
      transcript: 'new',
      title: 'new title',
    );
    expect(edited.transcript, 'new');
    expect(edited.title, 'new title');

    final Recording untitled = edited.copyWith(clearTitle: true);
    expect(untitled.title, isNull);
    expect(untitled.transcript, 'new'); // unaffected
  });

  test('legacy JSON defaults to not reviewed', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': DateTime.utc(2026, 7, 20).toIso8601String(),
      'durationMs': 900,
      'status': RecordingStatus.saved.name,
      'transcript': null,
      'error': null,
    });

    expect(restored.isProcessedByUser, isFalse);
    expect(restored.processedAt, isNull);
    expect(restored.title, isNull); // no title key on legacy rows
  });

  test('category, summary and tags round-trip through JSON', () {
    final Recording item = Recording(
      id: 'id-1',
      filePath: '/tmp/id-1.m4a',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      durationMs: 4200,
      status: RecordingStatus.completed,
      category: CaptureCategory.meetingNote,
      summary: 'Ustalenia ze spotkania.',
      tags: const <String>['klient', 'oferta'],
      projectId: 'augustyniak-capture',
    );

    final Recording restored = Recording.fromJson(item.toJson());

    expect(restored.category, CaptureCategory.meetingNote);
    expect(restored.summary, 'Ustalenia ze spotkania.');
    expect(restored.tags, <String>['klient', 'oferta']);
    expect(restored.projectId, 'augustyniak-capture');
  });

  test('routes round-trip through JSON', () {
    final Recording item = Recording(
      id: 'routed',
      filePath: '/tmp/routed.m4a',
      createdAt: DateTime.utc(2026, 8, 4, 17, 9),
      durationMs: 5000,
      status: RecordingStatus.completed,
      routes: <RouteRecord>[
        RouteRecord(
          at: DateTime.utc(2026, 8, 4, 17, 20),
          kind: RouteKind.file,
          target: 'inbox.md · Acme',
        ),
      ],
    );

    final Recording restored = Recording.fromJson(item.toJson());

    expect(restored.routes, hasLength(1));
    expect(restored.routes.single.kind, RouteKind.file);
    expect(restored.routes.single.target, 'inbox.md · Acme');
    expect(restored.routes.single.at, DateTime.utc(2026, 8, 4, 17, 20));
  });

  test('legacy JSON has no routes', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
    });

    expect(restored.routes, isEmpty);
  });

  test('an unreadable route row is dropped without taking the others', () {
    // The rule every other field on this type follows: a hand-edited
    // recordings.json, or a row written by a build that knew a destination this
    // one does not, must cost that row and nothing more. Throwing here would
    // take the whole index down — the failure mode the durability rules exist
    // to prevent.
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'mixed',
      'filePath': '/tmp/mixed.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'routes': <Object?>[
        <String, dynamic>{'kind': 'telepathy', 'at': '2026-01-01T00:00:00.000', 'target': 'x'},
        <String, dynamic>{'kind': 'file', 'at': 'not-a-date', 'target': 'x'},
        <String, dynamic>{'kind': 'file', 'at': '2026-01-02T00:00:00.000', 'target': 'inbox.md'},
        'nonsense',
      ],
    });

    expect(restored.routes, hasLength(1));
    expect(restored.routes.single.target, 'inbox.md');
  });

  test('legacy JSON has no category, summary or tags', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
    });

    // Null, not `capture`: "never enriched" and "the model could not classify
    // it" are different states and the card renders them differently.
    expect(restored.category, isNull);
    expect(restored.summary, isNull);
    expect(restored.tags, isEmpty);
  });

  test('tags written with the retired provenance shape still load', () {
    // Rows in this shape are already on disk from the builds that stored an
    // owner per tag. Dropping the reader would not look like a regression — it
    // would silently empty every tagged capture on the next load.
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'provenance-era',
      'filePath': '/tmp/provenance.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'tags': <dynamic>[
        <String, dynamic>{'value': 'klient', 'source': 'ai'},
        <String, dynamic>{'value': 'oferta', 'source': 'human'},
        // A mixed file is possible: the two formats overlapped in time.
        'legal',
        // Duplicate across the shapes collapses to one tag.
        <String, dynamic>{'value': 'LEGAL', 'source': 'ai'},
      ],
    });

    // The retired `{value, source}` shape still loads — those rows are on disk
    // — but the owner is dropped, and a duplicate across the two shapes
    // collapses to one tag.
    expect(restored.tags, <String>['klient', 'oferta', 'legal']);
    // What goes back out is the plain list again.
    expect(restored.toJson()['tags'], everyElement(isA<String>()));
  });

  test('a category name from a newer build degrades to capture', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'future',
      'filePath': '/tmp/future.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'category': 'journal',
    });

    expect(restored.category, CaptureCategory.capture);
  });

  test('a non-string category or summary does not take the load down', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'corrupt',
      'filePath': '/tmp/corrupt.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'category': 7,
      'summary': <String>['nope'],
    });

    expect(restored.category, isNull);
    expect(restored.summary, isNull);
  });

  test('tags survive a non-list or mixed-type JSON value', () {
    final Recording broken = Recording.fromJson(<String, dynamic>{
      'id': 'broken',
      'filePath': '/tmp/broken.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'tags': <dynamic>['ok', 7, null],
    });
    final Recording wrongType = Recording.fromJson(<String, dynamic>{
      'id': 'wrong',
      'filePath': '/tmp/wrong.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'tags': 'klient',
    });

    expect(broken.tags, <String>['ok']);
    expect(wrongType.tags, isEmpty);
  });

  test('thumbPath round-trips, and legacy rows have none', () {
    final Recording item = Recording(
      id: 'vid',
      filePath: '/tmp/vid.mp4',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      durationMs: 12000,
      status: RecordingStatus.completed,
      thumbPath: '/tmp/vid.thumb.jpg',
    );

    expect(Recording.fromJson(item.toJson()).thumbPath, '/tmp/vid.thumb.jpg');

    final Recording legacy = Recording.fromJson(<String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.mp4',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
    });
    expect(legacy.thumbPath, isNull);
  });

  test('a non-string thumbPath degrades to null instead of throwing', () {
    final Recording restored = Recording.fromJson(<String, dynamic>{
      'id': 'corrupt-thumb',
      'filePath': '/tmp/corrupt.mp4',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      'thumbPath': 42,
    });

    expect(restored.thumbPath, isNull);
  });

  test('copyWith clears thumbPath explicitly', () {
    final Recording item = Recording(
      id: 'vid-2',
      filePath: '/tmp/vid-2.mp4',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      durationMs: 12000,
      status: RecordingStatus.completed,
      thumbPath: '/tmp/vid-2.thumb.jpg',
    );

    // Survives an unrelated transition — the poster is derived once and kept.
    expect(
      item.copyWith(status: RecordingStatus.failed).thumbPath,
      '/tmp/vid-2.thumb.jpg',
    );
    expect(item.copyWith(clearThumbPath: true).thumbPath, isNull);
  });

  test('copyWith clears category and summary explicitly', () {
    final Recording item = Recording(
      id: 'id-2',
      filePath: '/tmp/id-2.m4a',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      durationMs: 0,
      status: RecordingStatus.completed,
      category: CaptureCategory.task,
      summary: 'coś',
      tags: const <String>['a'],
    );

    final Recording cleared = item.copyWith(
      clearCategory: true,
      clearSummary: true,
    );

    expect(cleared.category, isNull);
    expect(cleared.summary, isNull);
    // Tags are not cleared by those flags — they have their own replacement.
    expect(cleared.tags, <String>['a']);
  });
}

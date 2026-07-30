import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_category.dart';
import 'package:voice_notes_phase1/features/recordings/domain/recording.dart';

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

    final Recording edited =
        original.copyWith(transcript: 'new', title: 'new title');
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
      tags: <String>['klient', 'oferta'],
    );

    final Recording restored = Recording.fromJson(item.toJson());

    expect(restored.category, CaptureCategory.meetingNote);
    expect(restored.summary, 'Ustalenia ze spotkania.');
    expect(restored.tags, <String>['klient', 'oferta']);
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

  test('copyWith clears category and summary explicitly', () {
    final Recording item = Recording(
      id: 'id-2',
      filePath: '/tmp/id-2.m4a',
      createdAt: DateTime.utc(2026, 7, 30, 10),
      durationMs: 0,
      status: RecordingStatus.completed,
      category: CaptureCategory.task,
      summary: 'coś',
      tags: <String>['a'],
    );

    final Recording cleared =
        item.copyWith(clearCategory: true, clearSummary: true);

    expect(cleared.category, isNull);
    expect(cleared.summary, isNull);
    // Tags are not cleared by those flags — they have their own replacement.
    expect(cleared.tags, <String>['a']);
  });
}

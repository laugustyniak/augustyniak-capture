import 'package:flutter_test/flutter_test.dart';
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
      isProcessedByUser: true,
      processedAt: processedAt,
    );

    final Recording restored = Recording.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.status, RecordingStatus.completed);
    expect(restored.transcript, 'Test');
    expect(restored.isProcessedByUser, isTrue);
    expect(restored.processedAt, processedAt);
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
  });
}

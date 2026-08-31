import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10, 30);

  CaptureSegment sample({int index = 1, String? text}) => CaptureSegment(
    index: index,
    filePath: '/tmp/recordings/abc-$index.m4a',
    type: CaptureType.audioRecording,
    sourceMimeType: 'audio/mp4',
    createdAt: at,
    durationMs: 4200,
    sizeBytes: 1024,
    contentHash: 'a' * 64,
    text: text,
  );

  group('CaptureSegment', () {
    test('round-trips through JSON', () {
      final CaptureSegment restored = CaptureSegment.fromJson(
        sample(text: 'hello').toJson(),
      );
      expect(restored.index, 1);
      expect(restored.filePath, '/tmp/recordings/abc-1.m4a');
      expect(restored.type, CaptureType.audioRecording);
      expect(restored.sourceMimeType, 'audio/mp4');
      expect(restored.createdAt, at);
      expect(restored.durationMs, 4200);
      expect(restored.sizeBytes, 1024);
      expect(restored.contentHash, 'a' * 64);
      expect(restored.text, 'hello');
      expect(restored.error, isNull);
    });

    test('is pending exactly while it has no text', () {
      expect(sample().isPending, isTrue);
      expect(sample(text: '').isPending, isFalse);
      expect(sample(text: 'done').isPending, isFalse);
    });

    test('copyWith clears text and error explicitly', () {
      final CaptureSegment failed = sample().copyWith(error: 'no profile');
      expect(failed.error, 'no profile');
      expect(failed.copyWith(clearError: true).error, isNull);
      expect(sample(text: 'x').copyWith(clearText: true).text, isNull);
    });

    test('an unknown type degrades rather than throwing', () {
      final Map<String, dynamic> json = sample().toJson()
        ..['type'] = 'hologram';
      expect(CaptureSegment.fromJson(json).type, CaptureType.audioRecording);
    });

    test('listFromJson drops unreadable rows one at a time', () {
      final List<CaptureSegment> parsed = CaptureSegment.listFromJson(
        <dynamic>[sample(index: 0).toJson(), 42, sample(index: 1).toJson()],
      );
      expect(parsed.map((CaptureSegment s) => s.index), <int>[0, 1]);
    });

    test('listFromJson answers empty for anything that is not a list', () {
      expect(CaptureSegment.listFromJson(null), isEmpty);
      expect(CaptureSegment.listFromJson('nope'), isEmpty);
    });
  });

  group('appendSegmentText', () {
    test('joins with a blank line', () {
      expect(appendSegmentText('first', 'second'), 'first\n\nsecond');
    });

    test('an empty existing text is replaced, not padded', () {
      expect(appendSegmentText(null, 'first'), 'first');
      expect(appendSegmentText('   ', 'first'), 'first');
    });

    test('a blank addition leaves the text alone', () {
      expect(appendSegmentText('first', '   '), 'first');
      expect(appendSegmentText(null, ''), '');
    });
  });
}

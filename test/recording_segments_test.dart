import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';

void main() {
  final DateTime at = DateTime.utc(2026, 8, 28, 10);

  Recording base({List<CaptureSegment>? segments}) => Recording(
    id: 'abc',
    filePath: '/tmp/recordings/abc.m4a',
    createdAt: at,
    durationMs: 5000,
    sizeBytes: 2048,
    contentHash: 'b' * 64,
    status: RecordingStatus.completed,
    type: CaptureType.audioRecording,
    transcript: 'first fragment',
    segments: segments,
  );

  Recording withTwo() => base(
    segments: <CaptureSegment>[
      CaptureSegment(
        index: 0,
        filePath: '/tmp/recordings/abc.m4a',
        type: CaptureType.audioRecording,
        createdAt: at,
        durationMs: 5000,
        sizeBytes: 2048,
        contentHash: 'b' * 64,
        text: 'first fragment',
      ),
      CaptureSegment(
        index: 1,
        filePath: '/tmp/recordings/abc-1.txt',
        type: CaptureType.text,
        createdAt: at,
        sizeBytes: 12,
        text: 'second fragment',
      ),
    ],
  );

  group('a row with no stored segments', () {
    test('synthesises exactly one segment from the top-level fields', () {
      final List<CaptureSegment> segments = base().segments;
      expect(segments, hasLength(1));
      expect(segments.single.index, 0);
      expect(segments.single.filePath, '/tmp/recordings/abc.m4a');
      expect(segments.single.type, CaptureType.audioRecording);
      expect(segments.single.durationMs, 5000);
      expect(segments.single.sizeBytes, 2048);
      expect(segments.single.contentHash, 'b' * 64);
      expect(segments.single.text, 'first fragment');
      expect(base().hasStoredSegments, isFalse);
    });

    test('serialises byte for byte as before', () {
      expect(base().toJson().containsKey('segments'), isFalse);
    });

    test('legacy JSON with no segments key loads as one segment', () {
      final Recording restored = Recording.fromJson(base().toJson());
      expect(restored.segments, hasLength(1));
      expect(restored.hasStoredSegments, isFalse);
    });
  });

  group('a row with stored segments', () {
    test('round-trips through JSON', () {
      final Recording restored = Recording.fromJson(withTwo().toJson());
      expect(restored.hasStoredSegments, isTrue);
      expect(restored.segments, hasLength(2));
      expect(restored.segments[1].type, CaptureType.text);
      expect(restored.segments[1].text, 'second fragment');
    });

    test('top-level source fields still describe segment 0 exactly', () {
      final Recording item = withTwo();
      expect(item.filePath, item.segments.first.filePath);
      expect(item.sizeBytes, item.segments.first.sizeBytes);
      expect(item.contentHash, item.segments.first.contentHash);
      expect(item.durationMs, item.segments.first.durationMs);
    });

    test('aggregates are getters, never the persisted fields', () {
      expect(withTwo().totalDurationMs, 5000);
      expect(withTwo().totalSizeBytes, 2060);
    });

    test('nextSegmentIndex is one past the highest index in use', () {
      expect(base().nextSegmentIndex, 1);
      expect(withTwo().nextSegmentIndex, 2);
    });

    test('an empty stored list falls back to synthesis', () {
      final Map<String, dynamic> json = base().toJson()
        ..['segments'] = <dynamic>[];
      final Recording restored = Recording.fromJson(json);
      expect(restored.segments, hasLength(1));
      expect(restored.hasStoredSegments, isFalse);
    });

    test('copyWith carries the segments through an unrelated change', () {
      final Recording renamed = withTwo().copyWith(title: 'Plan');
      expect(renamed.segments, hasLength(2));
      expect(renamed.title, 'Plan');
    });
  });
}

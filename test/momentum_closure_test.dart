import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClosureEvent', () {
    test('round-trips through JSON', () {
      final ClosureEvent event = ClosureEvent(
        recordingId: 'abc',
        at: DateTime(2026, 8, 9, 14, 30),
        kind: ClosureKind.route,
        type: CaptureType.text,
        projectId: 'p1',
        projectName: 'Capture',
      );

      final ClosureEvent? back = ClosureEvent.fromJson(
        Map<String, dynamic>.from(event.toJson()),
      );

      expect(back, isNotNull);
      expect(back!.recordingId, 'abc');
      expect(back.at, DateTime(2026, 8, 9, 14, 30));
      expect(back.kind, ClosureKind.route);
      expect(back.type, CaptureType.text);
      expect(back.projectId, 'p1');
      expect(back.projectName, 'Capture');
    });

    test('omits absent optional fields rather than writing nulls', () {
      final ClosureEvent event = ClosureEvent(
        recordingId: 'abc',
        at: DateTime(2026, 8, 9),
        kind: ClosureKind.review,
        type: CaptureType.audioRecording,
      );

      expect(event.toJson().containsKey('projectId'), isFalse);
      expect(event.toJson().containsKey('projectName'), isFalse);
    });

    test('a row with an unknown kind is dropped, not defaulted', () {
      // Unlike `CaptureType.fromName` there is no sensible kind to assume, and
      // counting a newer build's kind as `review` would be a quiet lie about
      // how the work left the desk. The rule `RouteKind.fromName` follows.
      final ClosureEvent? back = ClosureEvent.fromJson(<String, dynamic>{
        'recordingId': 'abc',
        'at': DateTime(2026, 8, 9).toIso8601String(),
        'kind': 'teleported',
        'type': 'text',
      });

      expect(back, isNull);
    });

    test('an unknown capture type still defaults, like CaptureType.fromName', () {
      // Getting the icon wrong is not a lie about what happened, so this one
      // degrades rather than dropping the row.
      final ClosureEvent? back = ClosureEvent.fromJson(<String, dynamic>{
        'recordingId': 'abc',
        'at': DateTime(2026, 8, 9).toIso8601String(),
        'kind': 'review',
        'type': 'hologram',
      });

      expect(back, isNotNull);
      expect(back!.type, CaptureType.audioRecording);
    });

    test('a row missing a required field is dropped', () {
      expect(
        ClosureEvent.fromJson(<String, dynamic>{'recordingId': 'abc'}),
        isNull,
      );
      expect(ClosureEvent.fromJson('not a map'), isNull);
      expect(ClosureEvent.fromJson(null), isNull);
    });

    test('an unparseable timestamp is dropped rather than defaulted to now', () {
      expect(
        ClosureEvent.fromJson(<String, dynamic>{
          'recordingId': 'abc',
          'at': 'yesterday-ish',
          'kind': 'review',
          'type': 'text',
        }),
        isNull,
      );
    });
  });

  group('NoopClosureLog', () {
    test('loads nothing and accepts appends', () async {
      const NoopClosureLog log = NoopClosureLog();
      await log.append(
        ClosureEvent(
          recordingId: 'a',
          at: DateTime(2026, 1, 1),
          kind: ClosureKind.review,
          type: CaptureType.text,
        ),
      );
      expect(await log.load(), isEmpty);
    });
  });
}

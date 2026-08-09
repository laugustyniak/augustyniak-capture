import 'dart:convert';

import 'package:augustyniak_capture/features/momentum/data/file_closure_log.dart';
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/momentum/data/notifying_closure_log.dart';
import 'package:flutter_test/flutter_test.dart';

class _CollectingLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => appended;

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

class _RefusingLog implements ClosureLog {
  const _RefusingLog();

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async =>
      throw Exception('disk full');
}

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

  group('FileClosureLog.parse', () {
    String row(String id, String kind) => jsonEncode(<String, dynamic>{
      'recordingId': id,
      'at': DateTime(2026, 8, 9).toIso8601String(),
      'kind': kind,
      'type': 'text',
    });

    test('reads one event per line', () {
      final String raw = <String>[row('a', 'review'), row('b', 'route')].join(
        '\n',
      );

      expect(FileClosureLog.parse(raw).length, 2);
    });

    test('a torn final line costs one event, never the file', () {
      // The failure a kill mid-append actually produces. Losing the whole
      // history to one half-written row is the shape this store exists to
      // avoid.
      final String raw = '${row('a', 'review')}\n{"recordingId":"b","at":';

      final List<ClosureEvent> events = FileClosureLog.parse(raw);

      expect(events.length, 1);
      expect(events.single.recordingId, 'a');
    });

    test('a row from a newer build is skipped, and the rest survive', () {
      final String raw = <String>[
        row('a', 'review'),
        row('b', 'teleported'),
        row('c', 'handoff'),
      ].join('\n');

      final List<ClosureEvent> events = FileClosureLog.parse(raw);

      expect(events.map((ClosureEvent e) => e.recordingId), <String>['a', 'c']);
    });

    test('blank lines are skipped', () {
      expect(FileClosureLog.parse('\n\n  \n'), isEmpty);
      expect(FileClosureLog.parse(''), isEmpty);
    });
  });

  group('NotifyingClosureLog', () {
    ClosureEvent event() => ClosureEvent(
      recordingId: 'a',
      at: DateTime(2026, 8, 9),
      kind: ClosureKind.review,
      type: CaptureType.text,
    );

    test('hands each appended event to the listener', () async {
      final List<ClosureEvent> seen = <ClosureEvent>[];
      final _CollectingLog inner = _CollectingLog();
      final NotifyingClosureLog log = NotifyingClosureLog(inner, seen.add);

      await log.append(event());

      expect(inner.appended.length, 1);
      expect(seen.single.recordingId, 'a');
    });

    test('says nothing when the inner append fails', () async {
      // Reporting a closure the store rejected would put a number on screen
      // that the next launch silently takes back.
      final List<ClosureEvent> seen = <ClosureEvent>[];
      final NotifyingClosureLog log = NotifyingClosureLog(
        const _RefusingLog(),
        seen.add,
      );

      await expectLater(log.append(event()), throwsA(isA<Exception>()));
      expect(seen, isEmpty);
    });

    test('load passes straight through', () async {
      final _CollectingLog inner = _CollectingLog()..appended.add(event());
      final NotifyingClosureLog log = NotifyingClosureLog(inner, (_) {});

      expect((await log.load()).single.recordingId, 'a');
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

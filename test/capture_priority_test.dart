import 'dart:convert';

import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_prompt.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Recording _recording({CapturePriority? priority, String? priorityReason}) =>
    Recording(
      id: 'abc',
      filePath: '/tmp/abc.m4a',
      createdAt: DateTime.utc(2026, 10, 3),
      durationMs: 1000,
      status: RecordingStatus.completed,
      priority: priority,
      priorityReason: priorityReason,
    );

Map<String, dynamic> _legacyJson([Map<String, dynamic> extra = const {}]) =>
    <String, dynamic>{
      'id': 'legacy',
      'filePath': '/tmp/legacy.m4a',
      'createdAt': '2026-01-01T00:00:00.000',
      'durationMs': 1000,
      'status': 'completed',
      ...extra,
    };

String _chatBody(Map<String, dynamic> content) => jsonEncode(<String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': jsonEncode(content)},
    },
  ],
});

void main() {
  group('CapturePriority', () {
    test('known names parse, case-insensitively', () {
      expect(CapturePriority.tryName('p0'), CapturePriority.p0);
      expect(CapturePriority.tryName('P2'), CapturePriority.p2);
      expect(CapturePriority.tryName(' p3 '), CapturePriority.p3);
    });

    test('unknown, blank and non-string values are unranked, not p3', () {
      expect(CapturePriority.tryName('urgent'), isNull);
      expect(CapturePriority.tryName(''), isNull);
      expect(CapturePriority.tryName(null), isNull);
      expect(CapturePriority.tryName(1), isNull);
    });

    test('p0 sorts before p3', () {
      expect(CapturePriority.p0.index, lessThan(CapturePriority.p3.index));
    });
  });

  group('Recording.priority', () {
    test('priority and its reason round-trip through JSON', () {
      final Recording restored = Recording.fromJson(
        _recording(
          priority: CapturePriority.p1,
          priorityReason: 'Serves the Q4 goal: ship the beta.',
        ).toJson(),
      );

      expect(restored.priority, CapturePriority.p1);
      expect(restored.priorityReason, 'Serves the Q4 goal: ship the beta.');
    });

    test('an unranked row keeps both keys out of the JSON', () {
      // Absent means "never ranked": the row must serialise exactly as it did
      // before priority existed.
      final Map<String, dynamic> json = _recording().toJson();

      expect(json.containsKey('priority'), isFalse);
      expect(json.containsKey('priorityReason'), isFalse);
    });

    test('legacy JSON is unranked', () {
      final Recording restored = Recording.fromJson(_legacyJson());

      expect(restored.priority, isNull);
      expect(restored.priorityReason, isNull);
    });

    test('an unreadable priority degrades to unranked, not to a throw', () {
      final Recording restored = Recording.fromJson(
        _legacyJson(<String, dynamic>{
          'priority': 'urgent',
          'priorityReason': <String>['nope'],
        }),
      );

      expect(restored.priority, isNull);
      expect(restored.priorityReason, isNull);
    });

    test('copyWith sets and clears priority and reason', () {
      final Recording ranked = _recording().copyWith(
        priority: CapturePriority.p0,
        priorityReason: 'Client deadline.',
      );
      expect(ranked.priority, CapturePriority.p0);
      expect(ranked.priorityReason, 'Client deadline.');

      // An unrelated edit keeps both.
      final Recording retitled = ranked.copyWith(title: 'x');
      expect(retitled.priority, CapturePriority.p0);
      expect(retitled.priorityReason, 'Client deadline.');

      final Recording cleared = ranked.copyWith(
        clearPriority: true,
        clearPriorityReason: true,
      );
      expect(cleared.priority, isNull);
      expect(cleared.priorityReason, isNull);
    });

    test('priority survives a round trip through a sync row', () {
      final Recording original = _recording(
        priority: CapturePriority.p2,
        priorityReason: 'Nice to have.',
      );

      final Recording? back = SyncRowCodec.recordingFromRow(
        SyncRowCodec.recording(original),
        local: original,
      );

      expect(back?.priority, CapturePriority.p2);
      expect(back?.priorityReason, 'Nice to have.');
    });

    test('an unranked sync row stays unranked', () {
      final Recording original = _recording();

      final Recording? back = SyncRowCodec.recordingFromRow(
        SyncRowCodec.recording(original),
      );

      expect(back?.priority, isNull);
      expect(back?.priorityReason, isNull);
    });
  });

  group('enrichment priority', () {
    test('a ranked response parses priority and reason', () {
      final EnrichmentResult result = HttpChatEnrichmentService.parseResponse(
        _chatBody(<String, dynamic>{
          'title': 'T',
          'category': 'task',
          'priority': 'P1',
          'priorityReason': '  Serves the Q4 goal.  ',
        }),
      );

      expect(result.priority, CapturePriority.p1);
      expect(result.priorityReason, 'Serves the Q4 goal.');
    });

    test('a missing or unknown priority is unranked, and drops the reason', () {
      final EnrichmentResult missing = HttpChatEnrichmentService.parseResponse(
        _chatBody(<String, dynamic>{'title': 'T', 'category': 'task'}),
      );
      expect(missing.priority, isNull);
      expect(missing.priorityReason, isNull);

      // A reason without a rank explains nothing, so it is not kept.
      final EnrichmentResult unknown = HttpChatEnrichmentService.parseResponse(
        _chatBody(<String, dynamic>{
          'title': 'T',
          'priority': 'urgent',
          'priorityReason': 'Because.',
        }),
      );
      expect(unknown.priority, isNull);
      expect(unknown.priorityReason, isNull);
    });

    test('an over-long reason is bounded', () {
      final EnrichmentResult result = HttpChatEnrichmentService.parseResponse(
        _chatBody(<String, dynamic>{
          'priority': 'p3',
          'priorityReason': 'x' * 5000,
        }),
      );

      expect(
        result.priorityReason!.length,
        lessThanOrEqualTo(HttpChatEnrichmentService.maxPriorityReasonChars + 1),
      );
    });

    test('the prompt asks for every priority and ranks against the soul', () {
      final String prompt = buildEnrichmentSystemPrompt(
        context: const EnrichmentContext(profile: 'Goal: ship the beta.'),
      );

      for (final CapturePriority priority in CapturePriority.values) {
        expect(prompt, contains('"${priority.name}"'));
      }
      expect(prompt, contains('"priorityReason"'));
      // The restated contract after the fenced context names priority too, or
      // a profile could talk the model out of it.
      final int fenceEnd = prompt.indexOf('--- END USER PROFILE ---');
      expect(prompt.indexOf('"priority"', fenceEnd), greaterThan(fenceEnd));
    });
  });
}

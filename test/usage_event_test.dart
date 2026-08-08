import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageEvent', () {
    test('round-trips every field', () {
      final UsageEvent event = UsageEvent(
        id: 'evt-1',
        captureId: 'cap-1',
        stage: UsageStage.enrichment,
        provider: 'api.openai.com',
        model: 'gpt-5.6-luna',
        at: DateTime.utc(2026, 8, 9, 12, 30),
        inputTokens: 1200,
        outputTokens: 90,
        audioSeconds: null,
        costUsd: 0.000348,
        unpricedReason: null,
      );

      final UsageEvent restored = UsageEvent.fromJson(event.toJson());

      expect(restored.id, 'evt-1');
      expect(restored.captureId, 'cap-1');
      expect(restored.stage, UsageStage.enrichment);
      expect(restored.provider, 'api.openai.com');
      expect(restored.model, 'gpt-5.6-luna');
      expect(restored.at, DateTime.utc(2026, 8, 9, 12, 30));
      expect(restored.inputTokens, 1200);
      expect(restored.outputTokens, 90);
      expect(restored.audioSeconds, isNull);
      expect(restored.costUsd, closeTo(0.000348, 1e-9));
      expect(restored.unpricedReason, isNull);
    });

    test('legacy JSON defaults every optional field', () {
      final UsageEvent restored = UsageEvent.fromJson(<String, dynamic>{
        'id': 'evt-2',
        'captureId': 'cap-2',
        'stage': 'transcription',
        'provider': 'api.groq.com',
        'model': 'whisper-large-v3-turbo',
        'at': '2026-08-09T12:30:00.000Z',
      });

      expect(restored.inputTokens, isNull);
      expect(restored.outputTokens, isNull);
      expect(restored.audioSeconds, isNull);
      expect(restored.costUsd, isNull);
      expect(restored.unpricedReason, isNull);
    });

    test('an unknown stage name drops the row rather than throwing', () {
      final List<UsageEvent> rows = UsageEvent.listFromJson(<dynamic>[
        <String, dynamic>{
          'id': 'evt-3',
          'captureId': 'cap-3',
          'stage': 'summarisation',
          'provider': 'x',
          'model': 'y',
          'at': '2026-08-09T12:30:00.000Z',
        },
        <String, dynamic>{
          'id': 'evt-4',
          'captureId': 'cap-3',
          'stage': 'ocr',
          'provider': 'x',
          'model': 'y',
          'at': '2026-08-09T12:30:00.000Z',
        },
      ]);

      expect(rows.map((UsageEvent e) => e.id), <String>['evt-4']);
    });

    test('an unknown unpriced reason degrades to null, keeping the row', () {
      final UsageEvent restored = UsageEvent.fromJson(<String, dynamic>{
        'id': 'evt-5',
        'captureId': 'cap-5',
        'stage': 'ocr',
        'provider': 'x',
        'model': 'y',
        'at': '2026-08-09T12:30:00.000Z',
        'unpricedReason': 'sanctionsHold',
      });

      expect(restored.unpricedReason, isNull);
    });

    test('copyWith can clear the unpriced reason when a cost arrives', () {
      final UsageEvent event = UsageEvent(
        id: 'evt-6',
        captureId: 'cap-6',
        stage: UsageStage.ocr,
        provider: 'x',
        model: 'y',
        at: DateTime.utc(2026, 8, 9),
        unpricedReason: UnpricedReason.noRate,
      );

      final UsageEvent priced =
          event.copyWith(costUsd: 0.01, clearUnpricedReason: true);

      expect(priced.costUsd, 0.01);
      expect(priced.unpricedReason, isNull);
    });
  });
}

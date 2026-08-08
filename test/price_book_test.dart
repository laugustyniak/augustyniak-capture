import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:flutter_test/flutter_test.dart';

UsageEvent _chat({
  String model = 'gpt-5.6-luna',
  String provider = 'api.openai.com',
  int? inputTokens = 1000000,
  int? outputTokens = 1000000,
}) {
  return UsageEvent(
    id: 'e',
    captureId: 'c',
    stage: UsageStage.enrichment,
    provider: provider,
    model: model,
    at: DateTime.utc(2026, 8, 9),
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

UsageEvent _audio({
  String model = 'gpt-transcribe',
  String provider = 'api.openai.com',
  double? audioSeconds = 600,
}) {
  return UsageEvent(
    id: 'e',
    captureId: 'c',
    stage: UsageStage.transcription,
    provider: provider,
    model: model,
    at: DateTime.utc(2026, 8, 9),
    audioSeconds: audioSeconds,
  );
}

void main() {
  group('PriceBook lookup', () {
    test('a default rate is found by model name', () {
      final ModelPrice? rate =
          const PriceBook().lookup('claude-haiku-4-5', 'api.anthropic.com');

      expect(rate?.inputPerMTok, 1.00);
      expect(rate?.outputPerMTok, 5.00);
    });

    test('an override wins over the default', () {
      const PriceBook book = PriceBook(
        overrides: <String, ModelPrice>{
          'claude-haiku-4-5': ModelPrice(inputPerMTok: 9, outputPerMTok: 99),
        },
      );

      expect(book.lookup('claude-haiku-4-5', 'x')?.inputPerMTok, 9);
    });

    test('an unknown model has no rate at all — not a zero', () {
      expect(const PriceBook().lookup('gpt-6-nova', 'api.openai.com'), isNull);
    });

    test('a local model carries an explicit zero, which is not null', () {
      final ModelPrice? rate =
          const PriceBook().lookup('qwen2.5vl', 'localhost:11434');

      expect(rate, isNotNull);
      expect(rate!.inputPerMTok, 0);
      expect(rate.outputPerMTok, 0);
    });

    test('a blank model falls back to the provider host as the key', () {
      expect(PriceBook.keyFor('', 'localhost:8080'), 'localhost:8080');
      expect(PriceBook.keyFor('whisper-1', 'api.openai.com'), 'whisper-1');
    });
  });

  group('pricing', () {
    test('chat cost is tokens times the per-million rates', () {
      // gpt-5.6-luna is $0.20 in / $1.20 out per 1M tokens.
      final PricedResult priced = const PriceBook().price(_chat());

      expect(priced.costUsd, closeTo(1.40, 1e-9));
      expect(priced.reason, isNull);
    });

    test('transcription cost is audio minutes times the per-minute rate', () {
      // gpt-transcribe is $0.0045 per minute; 600 s is 10 minutes.
      final PricedResult priced = const PriceBook().price(_audio());

      expect(priced.costUsd, closeTo(0.045, 1e-9));
      expect(priced.reason, isNull);
    });

    test('a groq per-hour rate is converted to per-minute', () {
      // whisper-large-v3-turbo is $0.04/hour, so one hour of audio is $0.04.
      final PricedResult priced = const PriceBook().price(
        _audio(
          model: 'whisper-large-v3-turbo',
          provider: 'api.groq.com',
          audioSeconds: 3600,
        ),
      );

      expect(priced.costUsd, closeTo(0.04, 1e-9));
    });

    test('no rate yields a null cost with reason noRate', () {
      final PricedResult priced =
          const PriceBook().price(_chat(model: 'gpt-6-nova'));

      expect(priced.costUsd, isNull);
      expect(priced.reason, UnpricedReason.noRate);
    });

    test('a rate with no quantity yields reason noQuantity, not noRate', () {
      final PricedResult priced =
          const PriceBook().price(_audio(audioSeconds: null));

      expect(priced.costUsd, isNull);
      expect(priced.reason, UnpricedReason.noQuantity);
    });

    test('a local model with a zero rate prices to exactly zero', () {
      final PricedResult priced = const PriceBook().price(
        _chat(model: 'qwen2.5vl', provider: 'localhost:11434'),
      );

      expect(priced.costUsd, 0);
      expect(priced.reason, isNull);
    });

    test('missing output tokens count as zero when input is present', () {
      final PricedResult priced = const PriceBook().price(
        _chat(outputTokens: null),
      );

      expect(priced.costUsd, closeTo(0.20, 1e-9));
    });
  });

  group('storage prices', () {
    test('defaults are the published R2 and Turso rates', () {
      expect(StoragePrice.defaults.r2PerGbMonth, 0.015);
      expect(StoragePrice.defaults.tursoPerGbMonth, 0.50);
    });

    test('round-trips', () {
      const StoragePrice price =
          StoragePrice(r2PerGbMonth: 0.02, tursoPerGbMonth: 0.75);

      final StoragePrice restored = StoragePrice.fromJson(price.toJson());

      expect(restored.r2PerGbMonth, 0.02);
      expect(restored.tursoPerGbMonth, 0.75);
    });
  });

  group('defaults table', () {
    test('every enrichment preset model has a rate', () {
      const List<String> models = <String>[
        'gpt-5.6-luna',
        'gpt-5.6-terra',
        'gpt-5.6-sol',
        'gpt-4o-mini',
        'claude-haiku-4-5',
        'claude-sonnet-5',
        'claude-opus-5',
        'claude-fable-5',
        'gemini-3.6-flash',
        'gemini-3.5-flash-lite',
        'gemini-3.1-pro',
        'llama-3.3-70b-versatile',
        'openai/gpt-oss-120b',
        'openai/gpt-oss-20b',
      ];

      for (final String model in models) {
        expect(
          PriceBookDefaults.rates[model]?.inputPerMTok,
          isNotNull,
          reason: '$model has no input rate',
        );
      }
    });

    test('every transcription preset model has a per-minute rate', () {
      const List<String> models = <String>[
        'gpt-transcribe',
        'gpt-4o-transcribe',
        'gpt-4o-mini-transcribe',
        'whisper-1',
        'whisper-large-v3-turbo',
        'whisper-large-v3',
      ];

      for (final String model in models) {
        expect(
          PriceBookDefaults.rates[model]?.perAudioMinute,
          isNotNull,
          reason: '$model has no per-minute rate',
        );
      }
    });
  });
}

import 'model_price.dart';
import 'usage_event.dart';

/// What pricing an event produced: an amount, or the reason there is none.
class PricedResult {
  const PricedResult.priced(double this.costUsd) : reason = null;
  const PricedResult.unpriced(UnpricedReason this.reason) : costUsd = null;

  final double? costUsd;
  final UnpricedReason? reason;
}

/// Storage rate, in USD per GB-month.
///
/// A separate type from the per-model map because it is a scalar rather than
/// a keyed table, and because storage is rendered as a monthly rate rather
/// than charged per capture. It prices the media bytes in the Supabase Storage
/// bucket only; the Postgres rows that describe them do not scale with audio
/// size, so no database rate is estimated.
///
/// Before #202 this held two rates — R2 for the media and Turso for the index
/// — under `r2PerGbMonth` / `tursoPerGbMonth`. Neither is a Storage rate, so
/// [fromJson] ignores both rather than reading one as the new value.
class StoragePrice {
  const StoragePrice({required this.storagePerGbMonth});

  final double storagePerGbMonth;

  /// Supabase Storage beyond the plan's included quota, read from
  /// supabase.com/pricing on 2026-09-28. The included quota is not modelled:
  /// which plan an install is on is not discoverable from here and is one
  /// override away.
  static const StoragePrice defaults = StoragePrice(storagePerGbMonth: 0.0213);

  static const String _key = 'storagePerGbMonth';

  /// Whether [json] carries a rate this build understands. A map holding only
  /// the retired keys is a legacy row, not an override — see
  /// `AppSettings.fromJson`.
  static bool isReadable(Map<String, dynamic> json) => json[_key] is num;

  Map<String, dynamic> toJson() => <String, dynamic>{_key: storagePerGbMonth};

  factory StoragePrice.fromJson(Map<String, dynamic> json) => StoragePrice(
    storagePerGbMonth:
        (json[_key] as num?)?.toDouble() ?? defaults.storagePerGbMonth,
  );
}

/// The shipped rate table.
///
/// **In code rather than in `settings.json` on purpose.** Providers move their
/// prices, and a later build must be able to ship a corrected table to everyone
/// who never edited one. Copying this map into settings on first write would
/// freeze every install on the prices of its installation day; only the entries
/// a user actually changes are persisted (`AppSettings.priceOverrides`).
///
/// Read from each provider's own pricing page on 2026-08-09:
///   developers.openai.com/api/docs/pricing
///   platform.claude.com/docs/en/about-claude/models/overview
///   ai.google.dev/gemini-api/docs/pricing
///   console.groq.com/docs/models
abstract final class PriceBookDefaults {
  /// Bump this whenever a rate below changes; the Config tab prints it so a
  /// stale table is visible rather than merely wrong.
  static final DateTime verifiedOn = DateTime.utc(2026, 8, 9);

  static const Map<String, ModelPrice> rates = <String, ModelPrice>{
    // --- OpenAI chat (USD per 1M tokens) ---
    'gpt-5.6-luna': ModelPrice(inputPerMTok: 0.20, outputPerMTok: 1.20),
    'gpt-5.6-terra': ModelPrice(inputPerMTok: 2.00, outputPerMTok: 12.00),
    'gpt-5.6-sol': ModelPrice(inputPerMTok: 5.00, outputPerMTok: 30.00),
    'gpt-4o-mini': ModelPrice(inputPerMTok: 0.15, outputPerMTok: 0.60),

    // --- OpenAI transcription (USD per minute of audio) ---
    // None of these bills by token, whatever their `usage` block reports.
    'gpt-transcribe': ModelPrice(perAudioMinute: 0.0045),
    'gpt-4o-transcribe': ModelPrice(perAudioMinute: 0.006),
    'gpt-4o-mini-transcribe': ModelPrice(perAudioMinute: 0.003),
    'whisper-1': ModelPrice(perAudioMinute: 0.006),

    // --- Anthropic (USD per 1M tokens) ---
    'claude-haiku-4-5': ModelPrice(inputPerMTok: 1.00, outputPerMTok: 5.00),
    // Sonnet 5 carries an introductory $2/$10 through 2026-08-31; the standard
    // rate is stored so the table does not silently become wrong in September.
    'claude-sonnet-5': ModelPrice(inputPerMTok: 3.00, outputPerMTok: 15.00),
    'claude-opus-5': ModelPrice(inputPerMTok: 5.00, outputPerMTok: 25.00),
    'claude-fable-5': ModelPrice(inputPerMTok: 10.00, outputPerMTok: 50.00),

    // --- Google Gemini (USD per 1M tokens) ---
    'gemini-3.6-flash': ModelPrice(inputPerMTok: 1.50, outputPerMTok: 7.50),
    'gemini-3.5-flash-lite': ModelPrice(
      inputPerMTok: 0.30,
      outputPerMTok: 2.50,
    ),
    // Gemini 3.1 Pro doubles above a 200k-token prompt. Enrichment input is
    // capped at 12 000 characters and OCR sends one image, so the short-prompt
    // rate is the one this app ever pays.
    'gemini-3.1-pro': ModelPrice(inputPerMTok: 2.00, outputPerMTok: 12.00),

    // --- Groq chat (USD per 1M tokens) ---
    'llama-3.3-70b-versatile': ModelPrice(
      inputPerMTok: 0.59,
      outputPerMTok: 0.79,
    ),
    'openai/gpt-oss-120b': ModelPrice(
      inputPerMTok: 0.15,
      outputPerMTok: 0.60,
    ),
    'openai/gpt-oss-20b': ModelPrice(
      inputPerMTok: 0.075,
      outputPerMTok: 0.30,
    ),

    // --- Groq transcription (published per hour, stored per minute) ---
    'whisper-large-v3-turbo': ModelPrice(perAudioMinute: 0.04 / 60),
    'whisper-large-v3': ModelPrice(perAudioMinute: 0.111 / 60),

    // --- Local models: a known zero, which is not the same as no rate ---
    'qwen2.5vl': ModelPrice(
      inputPerMTok: 0,
      outputPerMTok: 0,
      perAudioMinute: 0,
    ),
    'llama3.2-vision': ModelPrice(inputPerMTok: 0, outputPerMTok: 0),
    'gemma3': ModelPrice(inputPerMTok: 0, outputPerMTok: 0),
    'llava': ModelPrice(inputPerMTok: 0, outputPerMTok: 0),
  };
}

/// Resolves a model to a rate and an event to an amount.
class PriceBook {
  const PriceBook({this.overrides = const <String, ModelPrice>{}});

  /// Only what the user changed. Everything else comes from
  /// [PriceBookDefaults.rates].
  final Map<String, ModelPrice> overrides;

  /// The lookup key. Model name where there is one; the endpoint host
  /// otherwise, because a profile that sets no model (a local whisper.cpp
  /// server, a custom endpoint) still has exactly one thing that identifies it.
  static String keyFor(String model, String provider) {
    final String trimmed = model.trim();
    return trimmed.isEmpty ? provider : trimmed;
  }

  ModelPrice? lookup(String model, String provider) {
    final String key = keyFor(model, provider);
    return overrides[key] ?? PriceBookDefaults.rates[key];
  }

  /// Price one event, or say why it cannot be priced.
  ///
  /// The two failure reasons are deliberately distinct: [UnpricedReason.noRate]
  /// sends the user to the rate table, [UnpricedReason.noQuantity] tells them
  /// no rate would have helped.
  PricedResult price(UsageEvent event) {
    final ModelPrice? rate = lookup(event.model, event.provider);
    if (rate == null) return const PricedResult.unpriced(UnpricedReason.noRate);

    if (event.stage == UsageStage.transcription) {
      final double? perMinute = rate.perAudioMinute;
      if (perMinute == null) {
        return const PricedResult.unpriced(UnpricedReason.noRate);
      }
      final double? seconds = event.audioSeconds;
      if (seconds == null) {
        return const PricedResult.unpriced(UnpricedReason.noQuantity);
      }
      return PricedResult.priced(seconds / 60 * perMinute);
    }

    final double? input = rate.inputPerMTok;
    final double? output = rate.outputPerMTok;
    if (input == null && output == null) {
      return const PricedResult.unpriced(UnpricedReason.noRate);
    }
    if (event.inputTokens == null && event.outputTokens == null) {
      return const PricedResult.unpriced(UnpricedReason.noQuantity);
    }
    // A rate can be half-filled — the editor commits each field independently,
    // so a model with no shipped default can pick up just one side. Pricing
    // the other side at `?? 0` would understate the total rather than refuse
    // it: an event that reports tokens on a side with no rate has an unknown
    // cost for that side, not a free one. `ModelPrice`'s null-means-unbilled
    // contract applies to the rate *and* to what an unrated side may charge.
    if (event.inputTokens != null && input == null) {
      return const PricedResult.unpriced(UnpricedReason.noRate);
    }
    if (event.outputTokens != null && output == null) {
      return const PricedResult.unpriced(UnpricedReason.noRate);
    }
    final double cost = (event.inputTokens ?? 0) / 1000000 * (input ?? 0) +
        (event.outputTokens ?? 0) / 1000000 * (output ?? 0);
    return PricedResult.priced(cost);
  }
}

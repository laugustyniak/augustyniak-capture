# Capture Cost Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what each capture cost — transcription, OCR, enrichment and storage — from usage the providers actually report, priced by an editable rate table in the Config tab.

**Architecture:** A new `lib/features/costs/` feature. A `UsageSink` seam (the shape of `LogSink`/`ClipboardSink`) is injected into the three HTTP services; each records one `UsageEvent` per response into a new `usage_events` SQLite table. `RecordingsController._processOne` scopes events to a capture with an explicit `beginJob`/`endJob` pair. A `PriceBook` — defaults in code, overrides in `AppSettings` — turns usage into dollars at record time.

**Tech Stack:** Dart 3.10+, Flutter, `sqlite3` (already the app's store), `http`, `uuid`. No new dependencies.

## Global Constraints

- **There is no CI.** `flutter analyze && flutter test` is the only gate; both must be clean before every commit.
- **Every new test must be seen red before it is trusted.** Break the implementation, run the test, watch it fail, restore. A test never seen failing is an assumption.
- **User-facing strings, identifiers and comments are English.** No Polish in the codebase.
- **A widget that paints a `Console` palette colour must not have a `const` constructor.** `test/theme_test.dart` scans `lib/` for violations.
- **Best-effort contract (the `ClipboardSink` rule):** cost recording never throws into the pipeline. Every failure is swallowed into `LogSink`. A failed cost write costs a number, never a capture.
- **`fromJson` stays backward compatible:** every new field defaults when absent; unknown enum names degrade rather than throw.
- **Never `git checkout -- <file>` in a dirty tree** to undo a temporary edit — it takes every other uncommitted change in that file with it. Copy the file to the scratchpad and copy it back.
- **Provider rates below were read from the providers' pricing pages on 2026-08-09.** Use them verbatim; do not substitute values from memory.

---

## File Structure

| Path | Responsibility |
|---|---|
| `lib/features/costs/domain/usage_event.dart` | `UsageEvent`, `UsageStage`, `UnpricedReason` — one API call, its measured quantities, its price |
| `lib/features/costs/domain/model_price.dart` | `ModelPrice` and the cost arithmetic |
| `lib/features/costs/domain/price_book.dart` | `PriceBookDefaults`, `PriceBook`, `StoragePrice` |
| `lib/features/costs/domain/usage_sink.dart` | `UsageSink` interface + `NoopUsageSink` |
| `lib/features/costs/domain/usage_parsing.dart` | Pure parser: response envelope → measured quantities |
| `lib/features/costs/data/usage_repository.dart` | SQLite persistence and aggregation queries |
| `lib/features/costs/data/recording_usage_sink.dart` | Prices an event and writes it; swallows everything |
| `lib/features/costs/presentation/pricing_section.dart` | The Config tab's `PRICING` section |
| `lib/features/costs/presentation/cost_section.dart` | The inline editor's `COST` section |
| `lib/core/database/app_database.dart` | *(modify)* the `usage_events` table |
| `lib/features/settings/domain/app_settings.dart` | *(modify)* `priceOverrides`, `storagePriceOverride` |
| `lib/features/transcription/data/transcription_service.dart` | *(modify)* emit usage |
| `lib/features/enrichment/data/http_chat_enrichment_service.dart` | *(modify)* emit usage |
| `lib/features/processing/data/http_vision_ocr_service.dart` | *(modify)* emit usage |
| `lib/features/settings/domain/provider_profile.dart` | *(modify)* pass the sink into the three services |
| `lib/features/settings/presentation/settings_controller.dart` | *(modify)* hold and inject the sink |
| `lib/features/recordings/presentation/recordings_controller.dart` | *(modify)* `beginJob`/`endJob` around the job and around `_enrich` |
| `lib/features/recordings/presentation/card_parts.dart` | *(modify)* cost on `VerificationLine` |

---

### Task 1: `UsageEvent` domain type

**Files:**
- Create: `lib/features/costs/domain/usage_event.dart`
- Test: `test/usage_event_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum UsageStage { transcription, ocr, enrichment }` with `static UsageStage? fromName(String?)`; `enum UnpricedReason { noRate, noQuantity }` with `static UnpricedReason? fromName(String?)`; `class UsageEvent` with fields `String id, String captureId, UsageStage stage, String provider, String model, DateTime at, int? inputTokens, int? outputTokens, double? audioSeconds, double? costUsd, UnpricedReason? unpricedReason`, plus `Map<String, dynamic> toJson()`, `factory UsageEvent.fromJson(Map<String, dynamic>)`, `static List<UsageEvent> listFromJson(dynamic)` and `UsageEvent copyWith({double? costUsd, UnpricedReason? unpricedReason, bool clearUnpricedReason})`.

- [ ] **Step 1: Write the failing test**

Create `test/usage_event_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/usage_event_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../usage_event.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/domain/usage_event.dart`:

```dart
/// Which pipeline stage spent the money.
///
/// Unlike [UnpricedReason], an unrecognised stage **drops the row**: there is no
/// sensible stage to assume, and filing a cost under the wrong stage is worse
/// than losing one row of history. Same rule `RouteKind.fromName` follows.
enum UsageStage {
  transcription,
  ocr,
  enrichment;

  static UsageStage? fromName(String? name) =>
      name == null ? null : UsageStage.values.asNameMap()[name];

  /// Section label in the editor's COST panel.
  String get label => switch (this) {
    UsageStage.transcription => 'TRANSCRIPTION',
    UsageStage.ocr => 'OCR',
    UsageStage.enrichment => 'ENRICHMENT',
  };
}

/// Why an event carries no cost. Set **exactly when** `costUsd` is null.
///
/// The two are not interchangeable and must not be shown together: [noRate] is
/// fixed by typing a rate in the Config tab and is backfillable afterwards,
/// while [noQuantity] means the rate exists and the billable amount is unknown —
/// typing a rate there fixes nothing.
enum UnpricedReason {
  /// The price book had no entry for this model.
  noRate,

  /// The provider reported no billable quantity and none could be supplied.
  noQuantity;

  /// Unknown names degrade to null rather than dropping the row: the row's
  /// tokens and model are still worth keeping, and the reason is a hint.
  static UnpricedReason? fromName(String? name) =>
      name == null ? null : UnpricedReason.values.asNameMap()[name];
}

/// One API call, what it consumed, and what it cost.
///
/// One capture produces several of these: a long recording is split into N
/// transcription requests, a retry runs the whole pass again, and enrichment is
/// its own request after the transcript lands. The cost of a capture is a sum
/// over this list, never a single field.
class UsageEvent {
  const UsageEvent({
    required this.id,
    required this.captureId,
    required this.stage,
    required this.provider,
    required this.model,
    required this.at,
    this.inputTokens,
    this.outputTokens,
    this.audioSeconds,
    this.costUsd,
    this.unpricedReason,
  });

  final String id;
  final String captureId;
  final UsageStage stage;

  /// Endpoint host (`api.openai.com`), so the Config tab can group by provider
  /// and name the endpoint behind a blank model.
  final String provider;

  /// Model name, or `''` when the profile sets none (a local server that
  /// ignores the field). Blank is a real state, not a missing one.
  final String model;
  final DateTime at;

  /// Null when the provider reported none. Detail rather than price basis for
  /// [UsageStage.transcription], which every supported provider bills by time.
  final int? inputTokens;
  final int? outputTokens;

  /// The billable quantity for [UsageStage.transcription]. Null when neither
  /// the response nor the capture could supply it.
  final double? audioSeconds;

  /// Computed and stored at record time, because it is a fact about what was
  /// paid. A later price change must not rewrite it; only a null is ever
  /// backfilled.
  final double? costUsd;

  /// Set exactly when [costUsd] is null.
  final UnpricedReason? unpricedReason;

  UsageEvent copyWith({
    double? costUsd,
    UnpricedReason? unpricedReason,
    bool clearUnpricedReason = false,
  }) {
    return UsageEvent(
      id: id,
      captureId: captureId,
      stage: stage,
      provider: provider,
      model: model,
      at: at,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      audioSeconds: audioSeconds,
      costUsd: costUsd ?? this.costUsd,
      unpricedReason: clearUnpricedReason
          ? null
          : (unpricedReason ?? this.unpricedReason),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'captureId': captureId,
    'stage': stage.name,
    'provider': provider,
    'model': model,
    'at': at.toIso8601String(),
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'audioSeconds': audioSeconds,
    'costUsd': costUsd,
    'unpricedReason': unpricedReason?.name,
  };

  /// Throws on a row with no usable stage; [listFromJson] is what turns that
  /// into a dropped row rather than a failed load.
  factory UsageEvent.fromJson(Map<String, dynamic> json) {
    final UsageStage? stage = UsageStage.fromName(json['stage'] as String?);
    if (stage == null) {
      throw FormatException('Unknown usage stage: ${json['stage']}');
    }
    return UsageEvent(
      id: json['id'] as String,
      captureId: json['captureId'] as String,
      stage: stage,
      provider: json['provider'] as String? ?? '',
      model: json['model'] as String? ?? '',
      at: DateTime.parse(json['at'] as String),
      inputTokens: (json['inputTokens'] as num?)?.toInt(),
      outputTokens: (json['outputTokens'] as num?)?.toInt(),
      audioSeconds: (json['audioSeconds'] as num?)?.toDouble(),
      costUsd: (json['costUsd'] as num?)?.toDouble(),
      unpricedReason: UnpricedReason.fromName(
        json['unpricedReason'] as String?,
      ),
    );
  }

  /// Unreadable rows are dropped one at a time rather than taking the whole
  /// load down — the same rule `RouteRecord.listFromJson` follows.
  static List<UsageEvent> listFromJson(dynamic value) {
    if (value is! List<dynamic>) return const <UsageEvent>[];
    final List<UsageEvent> events = <UsageEvent>[];
    for (final dynamic item in value) {
      if (item is! Map<String, dynamic>) continue;
      try {
        events.add(UsageEvent.fromJson(item));
      } catch (_) {
        continue;
      }
    }
    return events;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/usage_event_test.dart`
Expected: PASS (5 tests)

Then prove the tests are not vacuous: temporarily change `UsageStage.fromName` to `?? UsageStage.transcription`, run again, watch "an unknown stage name drops the row" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/domain/usage_event.dart test/usage_event_test.dart
git commit -m "Record one usage event per API call"
```

---

### Task 2: `ModelPrice`, `PriceBook` and the shipped rates

**Files:**
- Create: `lib/features/costs/domain/model_price.dart`
- Create: `lib/features/costs/domain/price_book.dart`
- Test: `test/price_book_test.dart`

**Interfaces:**
- Consumes: `UsageEvent`, `UsageStage`, `UnpricedReason` from Task 1.
- Produces: `class ModelPrice` (`double? inputPerMTok, outputPerMTok, perAudioMinute`, `const ModelPrice({...})`, `Map<String, dynamic> toJson()`, `factory ModelPrice.fromJson(Map<String, dynamic>)`, `bool get isEmpty`); `class PriceBook` (`const PriceBook({Map<String, ModelPrice> overrides = const {}})`, `static String keyFor(String model, String provider)`, `ModelPrice? lookup(String model, String provider)`, `PricedResult price(UsageEvent event)`); `class PricedResult` (`double? costUsd`, `UnpricedReason? reason`); `class StoragePrice` (`double r2PerGbMonth, tursoPerGbMonth`, `static const StoragePrice defaults`, JSON); `abstract final class PriceBookDefaults` (`static const Map<String, ModelPrice> rates`, `static final DateTime verifiedOn`).

- [ ] **Step 1: Write the failing test**

Create `test/price_book_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/price_book_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../model_price.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/domain/model_price.dart`:

```dart
/// What one model charges.
///
/// Every field is nullable because the two billing shapes are disjoint: a chat
/// model has token rates and no per-minute rate, a transcription model has the
/// opposite. A field that is null means "this model is not billed that way",
/// never "free".
class ModelPrice {
  const ModelPrice({
    this.inputPerMTok,
    this.outputPerMTok,
    this.perAudioMinute,
  });

  /// USD per 1 000 000 input tokens.
  final double? inputPerMTok;

  /// USD per 1 000 000 output tokens.
  final double? outputPerMTok;

  /// USD per minute of audio. Providers quoting an hourly rate are divided by
  /// 60 in the defaults table so this field has one unit everywhere.
  final double? perAudioMinute;

  /// True when the entry carries no rate at all — what an editor produces when
  /// every field is cleared, and what must not be stored as an override.
  bool get isEmpty =>
      inputPerMTok == null && outputPerMTok == null && perAudioMinute == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (inputPerMTok != null) 'inputPerMTok': inputPerMTok,
    if (outputPerMTok != null) 'outputPerMTok': outputPerMTok,
    if (perAudioMinute != null) 'perAudioMinute': perAudioMinute,
  };

  factory ModelPrice.fromJson(Map<String, dynamic> json) => ModelPrice(
    inputPerMTok: (json['inputPerMTok'] as num?)?.toDouble(),
    outputPerMTok: (json['outputPerMTok'] as num?)?.toDouble(),
    perAudioMinute: (json['perAudioMinute'] as num?)?.toDouble(),
  );
}
```

Create `lib/features/costs/domain/price_book.dart`:

```dart
import 'model_price.dart';
import 'usage_event.dart';

/// What pricing an event produced: an amount, or the reason there is none.
class PricedResult {
  const PricedResult.priced(double this.costUsd) : reason = null;
  const PricedResult.unpriced(UnpricedReason this.reason) : costUsd = null;

  final double? costUsd;
  final UnpricedReason? reason;
}

/// Storage rates, in USD per GB-month.
///
/// A separate type from the per-model map because these are two scalars rather
/// than a keyed table, and because storage is rendered as a monthly rate rather
/// than charged per capture.
class StoragePrice {
  const StoragePrice({
    required this.r2PerGbMonth,
    required this.tursoPerGbMonth,
  });

  final double r2PerGbMonth;
  final double tursoPerGbMonth;

  /// R2 Standard storage, and Turso's Scaler tier — the middle of the three
  /// published tiers, since the plan a given install is on is not discoverable
  /// from here and is one override away.
  static const StoragePrice defaults = StoragePrice(
    r2PerGbMonth: 0.015,
    tursoPerGbMonth: 0.50,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'r2PerGbMonth': r2PerGbMonth,
    'tursoPerGbMonth': tursoPerGbMonth,
  };

  factory StoragePrice.fromJson(Map<String, dynamic> json) => StoragePrice(
    r2PerGbMonth:
        (json['r2PerGbMonth'] as num?)?.toDouble() ?? defaults.r2PerGbMonth,
    tursoPerGbMonth: (json['tursoPerGbMonth'] as num?)?.toDouble() ??
        defaults.tursoPerGbMonth,
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
///   developers.cloudflare.com/r2/pricing
///   turso.tech/pricing
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
    final double cost = (event.inputTokens ?? 0) / 1000000 * (input ?? 0) +
        (event.outputTokens ?? 0) / 1000000 * (output ?? 0);
    return PricedResult.priced(cost);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/price_book_test.dart`
Expected: PASS (15 tests)

Prove non-vacuity: temporarily change `price` to return `const PricedResult.unpriced(UnpricedReason.noRate)` when the quantity is missing, run again, watch "a rate with no quantity yields reason noQuantity" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/domain/model_price.dart lib/features/costs/domain/price_book.dart test/price_book_test.dart
git commit -m "Ship a provider rate table and price usage against it"
```

---

### Task 3: `usage_events` table and `UsageRepository`

**Files:**
- Modify: `lib/core/database/app_database.dart` (inside `_initTables()`, after the `logs` index)
- Create: `lib/features/costs/data/usage_repository.dart`
- Test: `test/usage_repository_test.dart`

**Interfaces:**
- Consumes: `UsageEvent`, `UsageStage`, `UnpricedReason` (Task 1); `sqlite3`'s `Database`.
- Produces: `class UsageRepository` with `UsageRepository(Database db)`, `void insert(UsageEvent)`, `List<UsageEvent> forCapture(String captureId)`, `List<UsageEvent> all()`, `double totalSince(DateTime)`, `double totalAll()`, `Map<String, int> missingRateCounts()`, `int unknownQuantityCount()`, `int backfill(String key, PriceBook book)`.

- [ ] **Step 1: Write the failing test**

Create `test/usage_repository_test.dart`:

```dart
import 'package:augustyniak_capture/features/costs/data/usage_repository.dart';
import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

UsageEvent _event({
  required String id,
  String captureId = 'cap-1',
  UsageStage stage = UsageStage.enrichment,
  String model = 'gpt-5.6-luna',
  String provider = 'api.openai.com',
  DateTime? at,
  int? inputTokens = 1000,
  double? costUsd = 0.0002,
  UnpricedReason? unpricedReason,
}) {
  return UsageEvent(
    id: id,
    captureId: captureId,
    stage: stage,
    provider: provider,
    model: model,
    at: at ?? DateTime.utc(2026, 8, 9),
    inputTokens: inputTokens,
    costUsd: costUsd,
    unpricedReason: unpricedReason,
  );
}

void main() {
  late Database db;
  late UsageRepository repository;

  setUp(() {
    db = sqlite3.openInMemory();
    UsageRepository.createTable(db);
    repository = UsageRepository(db);
  });

  tearDown(() => db.dispose());

  test('an inserted event reads back whole', () {
    repository.insert(_event(id: 'e1'));

    final List<UsageEvent> rows = repository.forCapture('cap-1');

    expect(rows, hasLength(1));
    expect(rows.single.id, 'e1');
    expect(rows.single.model, 'gpt-5.6-luna');
    expect(rows.single.costUsd, closeTo(0.0002, 1e-9));
  });

  test('events of one capture sum across chunks and a retry', () {
    repository.insert(_event(id: 'e1', costUsd: 0.01));
    repository.insert(_event(id: 'e2', costUsd: 0.02));
    repository.insert(_event(id: 'e3', costUsd: 0.03));
    repository.insert(_event(id: 'e4', captureId: 'other', costUsd: 9.0));

    final double total = repository
        .forCapture('cap-1')
        .fold<double>(0, (double sum, UsageEvent e) => sum + (e.costUsd ?? 0));

    expect(total, closeTo(0.06, 1e-9));
  });

  test('totalSince counts only events at or after the boundary', () {
    repository.insert(_event(id: 'old', at: DateTime.utc(2026, 7, 31), costUsd: 5));
    repository.insert(_event(id: 'new', at: DateTime.utc(2026, 8, 1), costUsd: 2));

    expect(repository.totalSince(DateTime.utc(2026, 8, 1)), closeTo(2, 1e-9));
    expect(repository.totalAll(), closeTo(7, 1e-9));
  });

  test('missing-rate counts group by model and exclude other reasons', () {
    repository.insert(_event(
      id: 'a',
      model: 'gpt-6-nova',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(
      id: 'b',
      model: 'gpt-6-nova',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(
      id: 'c',
      model: 'whisper-1',
      costUsd: null,
      unpricedReason: UnpricedReason.noQuantity,
    ));

    expect(repository.missingRateCounts(), <String, int>{'gpt-6-nova': 2});
    expect(repository.unknownQuantityCount(), 1);
  });

  test('backfill prices only the null rows of that model', () {
    repository.insert(_event(
      id: 'a',
      model: 'gpt-6-nova',
      inputTokens: 1000000,
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(id: 'b', model: 'gpt-5.6-luna', costUsd: 0.5));

    const PriceBook book = PriceBook(
      overrides: <String, ModelPrice>{
        'gpt-6-nova': ModelPrice(inputPerMTok: 3, outputPerMTok: 9),
      },
    );

    final int updated = repository.backfill('gpt-6-nova', book);

    expect(updated, 1);
    final List<UsageEvent> rows = repository.all();
    final UsageEvent filled =
        rows.firstWhere((UsageEvent e) => e.id == 'a');
    final UsageEvent untouched =
        rows.firstWhere((UsageEvent e) => e.id == 'b');
    expect(filled.costUsd, closeTo(3, 1e-9));
    expect(filled.unpricedReason, isNull);
    expect(untouched.costUsd, closeTo(0.5, 1e-9));
  });

  test('backfill never rewrites a cost that is already recorded', () {
    repository.insert(_event(id: 'a', model: 'gpt-5.6-luna', costUsd: 0.5));

    const PriceBook book = PriceBook(
      overrides: <String, ModelPrice>{
        'gpt-5.6-luna': ModelPrice(inputPerMTok: 999, outputPerMTok: 999),
      },
    );

    expect(repository.backfill('gpt-5.6-luna', book), 0);
    expect(repository.all().single.costUsd, closeTo(0.5, 1e-9));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/usage_repository_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../usage_repository.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/data/usage_repository.dart`:

```dart
import 'package:sqlite3/sqlite3.dart';

import '../domain/price_book.dart';
import '../domain/usage_event.dart';

/// Persists one row per API call.
///
/// **Append-only in practice.** The single `UPDATE` is the backfill, and it is
/// scoped to rows that were never priced — a recorded cost is a fact about what
/// was paid and a later rate change must not rewrite it.
class UsageRepository {
  UsageRepository(this._db);

  final Database _db;

  /// Kept here rather than inline in `AppDatabase` so the tests can build the
  /// schema against an in-memory database without the app's path provider.
  /// `AppDatabase._initTables()` calls this.
  static void createTable(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS usage_events (
        id TEXT PRIMARY KEY,
        capture_id TEXT NOT NULL,
        stage TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        at INTEGER NOT NULL,
        input_tokens INTEGER,
        output_tokens INTEGER,
        audio_seconds REAL,
        cost_usd REAL,
        unpriced_reason TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_usage_capture
      ON usage_events(capture_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_usage_at ON usage_events(at DESC);
    ''');
  }

  void insert(UsageEvent event) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO usage_events
      (id, capture_id, stage, provider, model, at, input_tokens,
       output_tokens, audio_seconds, cost_usd, unpriced_reason)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      <Object?>[
        event.id,
        event.captureId,
        event.stage.name,
        event.provider,
        event.model,
        event.at.millisecondsSinceEpoch,
        event.inputTokens,
        event.outputTokens,
        event.audioSeconds,
        event.costUsd,
        event.unpricedReason?.name,
      ],
    );
  }

  List<UsageEvent> forCapture(String captureId) => _select(
    'SELECT * FROM usage_events WHERE capture_id = ? ORDER BY at ASC;',
    <Object?>[captureId],
  );

  List<UsageEvent> all() =>
      _select('SELECT * FROM usage_events ORDER BY at DESC;', <Object?>[]);

  double totalSince(DateTime from) {
    final ResultSet rows = _db.select(
      'SELECT SUM(cost_usd) AS total FROM usage_events WHERE at >= ?;',
      <Object?>[from.millisecondsSinceEpoch],
    );
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  double totalAll() {
    final ResultSet rows =
        _db.select('SELECT SUM(cost_usd) AS total FROM usage_events;');
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  /// Models whose events could not be priced **because no rate existed** —
  /// the only ones a rate would fix, and so the only ones the Config tab may
  /// offer a rate field for.
  Map<String, int> missingRateCounts() {
    final ResultSet rows = _db.select('''
      SELECT model, provider, COUNT(*) AS calls
      FROM usage_events
      WHERE unpriced_reason = 'noRate'
      GROUP BY model, provider;
    ''');
    return <String, int>{
      for (final Row row in rows)
        PriceBook.keyFor(row['model'] as String, row['provider'] as String):
            (row['calls'] as num).toInt(),
    };
  }

  /// Events whose rate is known and whose billable amount is not — reported
  /// separately, because no rate the user types would price them.
  int unknownQuantityCount() {
    final ResultSet rows = _db.select('''
      SELECT COUNT(*) AS calls FROM usage_events
      WHERE unpriced_reason = 'noQuantity';
    ''');
    return (rows.first['calls'] as num).toInt();
  }

  /// Price the rows that were never priced for this key. Returns how many rows
  /// changed. Rows with a recorded cost are untouched by construction: the
  /// `WHERE` clause cannot see them.
  int backfill(String key, PriceBook book) {
    final ResultSet rows = _db.select(
      '''
      SELECT * FROM usage_events
      WHERE cost_usd IS NULL AND (model = ? OR (model = '' AND provider = ?));
      ''',
      <Object?>[key, key],
    );

    int updated = 0;
    for (final Row row in rows) {
      final UsageEvent event = _fromRow(row);
      final PricedResult priced = book.price(event);
      if (priced.costUsd == null) continue;
      _db.execute(
        'UPDATE usage_events SET cost_usd = ?, unpriced_reason = NULL WHERE id = ?;',
        <Object?>[priced.costUsd, event.id],
      );
      updated++;
    }
    return updated;
  }

  List<UsageEvent> _select(String sql, List<Object?> params) =>
      <UsageEvent>[for (final Row row in _db.select(sql, params)) _fromRow(row)];

  static UsageEvent _fromRow(Row row) => UsageEvent(
    id: row['id'] as String,
    captureId: row['capture_id'] as String,
    // A row is only ever written from a `UsageStage`, so an unreadable stage
    // here means hand-edited data; fall back rather than throw out of a query
    // that the Config tab renders from.
    stage: UsageStage.fromName(row['stage'] as String?) ??
        UsageStage.enrichment,
    provider: row['provider'] as String,
    model: row['model'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(
      (row['at'] as num).toInt(),
      isUtc: true,
    ),
    inputTokens: (row['input_tokens'] as num?)?.toInt(),
    outputTokens: (row['output_tokens'] as num?)?.toInt(),
    audioSeconds: (row['audio_seconds'] as num?)?.toDouble(),
    costUsd: (row['cost_usd'] as num?)?.toDouble(),
    unpricedReason: UnpricedReason.fromName(row['unpriced_reason'] as String?),
  );
}
```

Then in `lib/core/database/app_database.dart`, add the import and the call at the end of `_initTables()`:

```dart
import '../../features/costs/data/usage_repository.dart';
```

```dart
    // Per-API-call cost history. Owned by UsageRepository so the same schema
    // builds against an in-memory database in tests.
    UsageRepository.createTable(_db);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/usage_repository_test.dart`
Expected: PASS (6 tests)

Prove non-vacuity: temporarily drop `AND cost_usd IS NULL` from the backfill query, run again, watch "backfill never rewrites a cost that is already recorded" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/data/usage_repository.dart lib/core/database/app_database.dart test/usage_repository_test.dart
git commit -m "Store usage events in SQLite and backfill unpriced rows"
```

---

### Task 4: usage parsing and the `UsageSink` seam

**Files:**
- Create: `lib/features/costs/domain/usage_sink.dart`
- Create: `lib/features/costs/domain/usage_parsing.dart`
- Test: `test/usage_parsing_test.dart`

**Interfaces:**
- Consumes: `UsageStage` (Task 1).
- Produces: `class MeasuredUsage` (`final int? inputTokens, outputTokens; final double? audioSeconds; const MeasuredUsage({...}); bool get isEmpty`); `MeasuredUsage parseUsage(Map<String, dynamic> envelope)`; `abstract interface class UsageSink` with `void beginJob(String captureId, UsageStage stage, {double? fallbackAudioSeconds})`, `void endJob()`, `void record({required String provider, required String model, required MeasuredUsage usage})`; `class NoopUsageSink implements UsageSink`.

- [ ] **Step 1: Write the failing test**

Create `test/usage_parsing_test.dart`:

```dart
import 'dart:convert';

import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _decode(String body) =>
    jsonDecode(body) as Map<String, dynamic>;

void main() {
  group('parseUsage', () {
    test('reads an OpenAI chat completion usage block', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"choices": [], "usage": {"prompt_tokens": 1200, "completion_tokens": 90}}
      '''));

      expect(usage.inputTokens, 1200);
      expect(usage.outputTokens, 90);
      expect(usage.audioSeconds, isNull);
    });

    test('reads the input_tokens/output_tokens spelling', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"usage": {"input_tokens": 800, "output_tokens": 40}}
      '''));

      expect(usage.inputTokens, 800);
      expect(usage.outputTokens, 40);
    });

    test('reads a duration usage block as audio seconds', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"text": "hi", "usage": {"type": "duration", "seconds": 137.5}}
      '''));

      expect(usage.audioSeconds, closeTo(137.5, 1e-9));
      expect(usage.inputTokens, isNull);
    });

    test('reads Groq usage nested under x_groq', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"text": "hi", "x_groq": {"usage": {"seconds": 42}}}
      '''));

      expect(usage.audioSeconds, closeTo(42, 1e-9));
    });

    test('a response with no usage block is empty, not an error', () {
      final MeasuredUsage usage = parseUsage(_decode('{"text": "hi"}'));

      expect(usage.isEmpty, isTrue);
      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, isNull);
      expect(usage.audioSeconds, isNull);
    });

    test('a non-numeric usage value is ignored rather than thrown', () {
      final MeasuredUsage usage = parseUsage(_decode('''
        {"usage": {"prompt_tokens": "many", "completion_tokens": 7}}
      '''));

      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, 7);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/usage_parsing_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../usage_parsing.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/domain/usage_parsing.dart`:

```dart
/// The quantities a provider reported for one call.
///
/// All nullable, because "not reported" is a real answer: a local whisper.cpp
/// or Ollama server returns no usage at all, and that is not an error — those
/// endpoints also charge nothing.
class MeasuredUsage {
  const MeasuredUsage({this.inputTokens, this.outputTokens, this.audioSeconds});

  static const MeasuredUsage none = MeasuredUsage();

  final int? inputTokens;
  final int? outputTokens;
  final double? audioSeconds;

  bool get isEmpty =>
      inputTokens == null && outputTokens == null && audioSeconds == null;
}

/// Pull the reported quantities out of a decoded response body.
///
/// Handles the three shapes the supported providers emit — chat completions
/// (`prompt_tokens`/`completion_tokens`), OpenAI transcriptions (either
/// `input_tokens`/`output_tokens` or `{"type": "duration", "seconds": N}`), and
/// Groq's `x_groq.usage`. Never throws: a missing or malformed block yields
/// [MeasuredUsage.none], because a response that transcribed correctly must not
/// fail over its accounting.
MeasuredUsage parseUsage(Map<String, dynamic> envelope) {
  final Map<String, dynamic>? usage =
      _asMap(envelope['usage']) ?? _asMap(_asMap(envelope['x_groq'])?['usage']);
  if (usage == null) return MeasuredUsage.none;

  return MeasuredUsage(
    inputTokens: _asInt(usage['prompt_tokens'] ?? usage['input_tokens']),
    outputTokens: _asInt(usage['completion_tokens'] ?? usage['output_tokens']),
    audioSeconds: _asDouble(usage['seconds'] ?? usage['duration']),
  );
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : null;

int? _asInt(dynamic value) => value is num ? value.toInt() : null;

double? _asDouble(dynamic value) => value is num ? value.toDouble() : null;
```

Create `lib/features/costs/domain/usage_sink.dart`:

```dart
import 'usage_event.dart';
import 'usage_parsing.dart';

/// Write-only seam that receives one call's usage.
///
/// **Deliberately not part of any service's return type.** The three HTTP
/// classes sit under one or two decorators that all declare `Future<String>`;
/// widening those would rewrite `Processor`, both audio processors, the
/// chunking decorator and every hand-written fake in the suite, and would force
/// the chunking decorator to sum usage itself. A sink changes no contract, and
/// chunking emits N events for free because every part goes through the same
/// HTTP class.
///
/// The HTTP classes do not know which capture they are working on;
/// [beginJob]/[endJob] supply it. That is ambient state, and it is safe for one
/// specific reason: `RecordingsController._drainProcessingQueue` is
/// single-flight and `_enrich` runs inside the same `_processOne`, so exactly
/// one job is ever active.
///
/// Defaults to a no-op so the pure-Dart suites need no database, exactly as
/// `NoopLogSink` and `NoopClipboardSink` do.
abstract interface class UsageSink {
  /// Scope subsequent [record] calls to this capture and stage.
  ///
  /// [fallbackAudioSeconds] is the capture's own measured duration, used only
  /// when the provider reports none. It is a measurement of the billed quantity
  /// rather than an estimate of it — but it is absent for uploads, which carry
  /// `durationMs: 0`.
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  });

  /// Leave the scope. Always called from a `finally`.
  void endJob();

  /// One successful API call.
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  });
}

class NoopUsageSink implements UsageSink {
  const NoopUsageSink();

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {}

  @override
  void endJob() {}

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/usage_parsing_test.dart`
Expected: PASS (6 tests)

Prove non-vacuity: temporarily make `_asInt` return `int.tryParse(value.toString())`, run again, watch "a non-numeric usage value is ignored" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/domain/usage_sink.dart lib/features/costs/domain/usage_parsing.dart test/usage_parsing_test.dart
git commit -m "Parse provider usage blocks behind a no-op sink seam"
```

---

### Task 5: emit usage from the three HTTP services

**Files:**
- Modify: `lib/features/transcription/data/transcription_service.dart:19-79`
- Modify: `lib/features/enrichment/data/http_chat_enrichment_service.dart:18-80`
- Modify: `lib/features/processing/data/http_vision_ocr_service.dart` (its constructor and the success branch of its POST)
- Modify: `lib/features/settings/domain/provider_profile.dart:113-159`
- Test: `test/usage_emission_test.dart`

**Interfaces:**
- Consumes: `UsageSink`, `NoopUsageSink`, `parseUsage`, `MeasuredUsage` (Task 4).
- Produces: each of `HttpWhisperTranscriptionService`, `HttpChatEnrichmentService` and `HttpVisionOcrService` gains a `UsageSink usageSink = const NoopUsageSink()` named parameter; `ProviderProfile.toService()`, `.toEnrichmentService()` and `.toOcrService()` each gain a `{UsageSink usageSink = const NoopUsageSink()}` parameter and pass it through.

- [ ] **Step 1: Write the failing test**

Create `test/usage_emission_test.dart`:

```dart
import 'dart:convert';

import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingSink implements UsageSink {
  final List<String> jobs = <String>[];
  final List<MeasuredUsage> recorded = <MeasuredUsage>[];
  final List<String> models = <String>[];
  int ends = 0;

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    jobs.add('$captureId/${stage.name}');
  }

  @override
  void endJob() => ends++;

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {
    models.add(model);
    recorded.add(usage);
  }
}

void main() {
  test('a successful enrichment response emits its usage once', () async {
    final _RecordingSink sink = _RecordingSink();
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content': '{"title":"T","category":"note","summary":"S","tags":[]}',
              },
            },
          ],
          'usage': <String, dynamic>{
            'prompt_tokens': 1200,
            'completion_tokens': 90,
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: sink,
    );

    await service.enrich('hello');

    expect(sink.recorded, hasLength(1));
    expect(sink.recorded.single.inputTokens, 1200);
    expect(sink.recorded.single.outputTokens, 90);
    expect(sink.models.single, 'gpt-5.6-luna');
  });

  test('a failed response emits nothing', () async {
    final _RecordingSink sink = _RecordingSink();
    final http.Client client = MockClient(
      (http.Request request) async => http.Response('nope', 500),
    );

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: sink,
    );

    await expectLater(service.enrich('hello'), throwsA(isA<Exception>()));
    expect(sink.recorded, isEmpty);
  });

  test('a throwing sink never fails the enrichment', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content': '{"title":"T","category":"note","summary":"S","tags":[]}',
              },
            },
          ],
          'usage': <String, dynamic>{'prompt_tokens': 1},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final HttpChatEnrichmentService service = HttpChatEnrichmentService(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      model: 'gpt-5.6-luna',
      client: client,
      usageSink: _ThrowingSink(),
    );

    final dynamic result = await service.enrich('hello');
    expect(result.title, 'T');
  });
}

class _ThrowingSink implements UsageSink {
  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) =>
      throw StateError('boom');

  @override
  void endJob() => throw StateError('boom');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) =>
      throw StateError('boom');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/usage_emission_test.dart`
Expected: FAIL — `No named parameter with the name 'usageSink'`

- [ ] **Step 3: Write minimal implementation**

In `lib/features/enrichment/data/http_chat_enrichment_service.dart`, add the imports, the field, and the emission. Constructor becomes:

```dart
  HttpChatEnrichmentService({
    required this.endpoint,
    this.bearerToken,
    this.model,
    http.Client? client,
    this.usageSink = const NoopUsageSink(),
  }) : _client = client ?? http.Client();
```

with the field:

```dart
  /// Receives what this call consumed. Defaults to a no-op, so nothing in the
  /// pure-Dart suite needs a database.
  final UsageSink usageSink;
```

and, in `enrich`, immediately after the non-2xx guard and before `parseResponse`:

```dart
    final String body = utf8.decode(response.bodyBytes);
    _recordUsage(body);
    return parseResponse(body);
```

plus the private helper:

```dart
  /// Accounting must never cost a capture: a malformed usage block, or a sink
  /// that throws, is swallowed here rather than turned into a failed
  /// enrichment. Same contract as `ClipboardSink`.
  void _recordUsage(String body) {
    try {
      final dynamic envelope = jsonDecode(body);
      if (envelope is! Map<String, dynamic>) return;
      usageSink.record(
        provider: endpoint.host,
        model: model ?? '',
        usage: parseUsage(envelope),
      );
    } catch (_) {
      // Deliberately silent.
    }
  }
```

Apply the identical three edits to `HttpWhisperTranscriptionService` (its success branch already holds the decoded `body` string — call `_recordUsage(body)` after the status check and before `jsonDecode`) and to `HttpVisionOcrService`.

Then in `lib/features/settings/domain/provider_profile.dart`, thread the sink through all three factories, e.g.:

```dart
  TranscriptionService toService({
    UsageSink usageSink = const NoopUsageSink(),
  }) {
    final Uri? uri = hasEndpoint ? Uri.tryParse(endpoint.trim()) : null;
    if (uri == null || !uri.hasScheme) {
      return const DisabledTranscriptionService();
    }
    return HttpWhisperTranscriptionService(
      endpoint: uri,
      bearerToken: usableBearerToken,
      model: _blankToNull(model),
      language: _blankToNull(language),
      usageSink: usageSink,
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/usage_emission_test.dart`
Expected: PASS (3 tests)

Prove non-vacuity: temporarily remove the `try`/`catch` from `_recordUsage`, run again, watch "a throwing sink never fails the enrichment" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/transcription lib/features/enrichment lib/features/processing lib/features/settings/domain/provider_profile.dart test/usage_emission_test.dart
git commit -m "Emit usage from the three HTTP services"
```

---

### Task 6: `RecordingUsageSink` — price and persist

**Files:**
- Create: `lib/features/costs/data/recording_usage_sink.dart`
- Test: `test/recording_usage_sink_test.dart`

**Interfaces:**
- Consumes: `UsageSink`, `MeasuredUsage` (Task 4); `UsageRepository` (Task 3); `PriceBook`, `PricedResult` (Task 2); `LogSink`, `NoopLogSink` from `lib/features/logs/domain/log_event.dart`.
- Produces: `class RecordingUsageSink implements UsageSink` with `RecordingUsageSink({required UsageRepository repository, required PriceBook Function() priceBook, String Function()? idFactory, DateTime Function()? clock, LogSink logSink = const NoopLogSink()})`.

- [ ] **Step 1: Write the failing test**

Create `test/recording_usage_sink_test.dart`:

```dart
import 'package:augustyniak_capture/features/costs/data/recording_usage_sink.dart';
import 'package:augustyniak_capture/features/costs/data/usage_repository.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late UsageRepository repository;
  late RecordingUsageSink sink;
  late int counter;

  setUp(() {
    db = sqlite3.openInMemory();
    UsageRepository.createTable(db);
    repository = UsageRepository(db);
    counter = 0;
    sink = RecordingUsageSink(
      repository: repository,
      priceBook: () => const PriceBook(),
      idFactory: () => 'evt-${counter++}',
      clock: () => DateTime.utc(2026, 8, 9),
    );
  });

  tearDown(() => db.dispose());

  test('an enrichment call is priced from its tokens', () {
    sink.beginJob('cap-1', UsageStage.enrichment);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 1000000, outputTokens: 1000000),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-1').single;
    expect(event.stage, UsageStage.enrichment);
    expect(event.costUsd, closeTo(1.40, 1e-9));
    expect(event.unpricedReason, isNull);
  });

  test('a transcription with no reported duration falls back to the capture', () {
    sink.beginJob(
      'cap-2',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(inputTokens: 900),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-2').single;
    expect(event.audioSeconds, closeTo(600, 1e-9));
    expect(event.costUsd, closeTo(0.045, 1e-9));
  });

  test('the reported duration wins over the fallback', () {
    sink.beginJob(
      'cap-3',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(audioSeconds: 120),
    );
    sink.endJob();

    expect(
      repository.forCapture('cap-3').single.audioSeconds,
      closeTo(120, 1e-9),
    );
  });

  test('the fallback is applied to the first chunk only, never multiplied', () {
    sink.beginJob(
      'cap-4',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    for (int i = 0; i < 3; i++) {
      sink.record(
        provider: 'api.openai.com',
        model: 'gpt-transcribe',
        usage: const MeasuredUsage(),
      );
    }
    sink.endJob();

    final List<UsageEvent> events = repository.forCapture('cap-4');
    expect(events, hasLength(3));
    final double total = events.fold<double>(
      0,
      (double sum, UsageEvent e) => sum + (e.audioSeconds ?? 0),
    );
    expect(total, closeTo(600, 1e-9));
  });

  test('an upload with no duration anywhere records reason noQuantity', () {
    sink.beginJob('cap-5', UsageStage.transcription);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(inputTokens: 900),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-5').single;
    expect(event.costUsd, isNull);
    expect(event.unpricedReason, UnpricedReason.noQuantity);
  });

  test('an unknown model records reason noRate with its tokens intact', () {
    sink.beginJob('cap-6', UsageStage.enrichment);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-6-nova',
      usage: const MeasuredUsage(inputTokens: 500, outputTokens: 20),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-6').single;
    expect(event.costUsd, isNull);
    expect(event.unpricedReason, UnpricedReason.noRate);
    expect(event.inputTokens, 500);
  });

  test('a record outside any job is dropped rather than misfiled', () {
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 10),
    );

    expect(repository.all(), isEmpty);
  });

  test('a repository that throws never propagates out of record', () {
    final RecordingUsageSink failing = RecordingUsageSink(
      repository: _ThrowingRepository(db),
      priceBook: () => const PriceBook(),
    );

    failing.beginJob('cap-7', UsageStage.enrichment);
    expect(
      () => failing.record(
        provider: 'p',
        model: 'gpt-5.6-luna',
        usage: const MeasuredUsage(inputTokens: 1),
      ),
      returnsNormally,
    );
    failing.endJob();
  });
}

class _ThrowingRepository extends UsageRepository {
  // `UsageRepository`'s field is private, so this cannot be a `super.db`
  // parameter — pass it positionally.
  _ThrowingRepository(Database db) : super(db);

  @override
  void insert(UsageEvent event) => throw StateError('disk is gone');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/recording_usage_sink_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../recording_usage_sink.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/data/recording_usage_sink.dart`:

```dart
import 'package:uuid/uuid.dart';

import '../../logs/domain/log_event.dart';
import '../domain/price_book.dart';
import '../domain/usage_event.dart';
import '../domain/usage_parsing.dart';
import '../domain/usage_sink.dart';
import 'usage_repository.dart';

/// Prices each reported call and writes it to the usage store.
///
/// Best-effort under the `ClipboardSink` contract: every failure is swallowed
/// into [LogSink]. A cost row that cannot be written costs a number; throwing
/// here would cost the capture the feature exists to measure.
class RecordingUsageSink implements UsageSink {
  RecordingUsageSink({
    required UsageRepository repository,
    required PriceBook Function() priceBook,
    String Function()? idFactory,
    DateTime Function()? clock,
    LogSink logSink = const NoopLogSink(),
  }) : _repository = repository,
       _priceBook = priceBook,
       _idFactory = idFactory ?? (() => const Uuid().v4()),
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _logSink = logSink;

  final UsageRepository _repository;

  /// Read per call rather than captured: a rate edited in the Config tab must
  /// reach the very next capture without rebuilding this object.
  final PriceBook Function() _priceBook;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  final LogSink _logSink;

  String? _captureId;
  UsageStage? _stage;
  double? _pendingFallbackSeconds;

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    _captureId = captureId;
    _stage = stage;
    // Held for the *first* event of the job only. A twenty-minute capture is
    // split into four requests; attaching the capture's full duration to each
    // of them would bill the same audio four times.
    _pendingFallbackSeconds =
        (fallbackAudioSeconds ?? 0) > 0 ? fallbackAudioSeconds : null;
  }

  @override
  void endJob() {
    _captureId = null;
    _stage = null;
    _pendingFallbackSeconds = null;
  }

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {
    final String? captureId = _captureId;
    final UsageStage? stage = _stage;
    // A call outside any job has no capture to bill. Dropping it is better than
    // filing it under whichever capture ran last.
    if (captureId == null || stage == null) return;

    try {
      final double? seconds = usage.audioSeconds ?? _takeFallbackSeconds();
      final UsageEvent unpriced = UsageEvent(
        id: _idFactory(),
        captureId: captureId,
        stage: stage,
        provider: provider,
        model: model,
        at: _clock(),
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        audioSeconds: seconds,
      );

      final PricedResult priced = _priceBook().price(unpriced);
      _repository.insert(
        UsageEvent(
          id: unpriced.id,
          captureId: unpriced.captureId,
          stage: unpriced.stage,
          provider: unpriced.provider,
          model: unpriced.model,
          at: unpriced.at,
          inputTokens: unpriced.inputTokens,
          outputTokens: unpriced.outputTokens,
          audioSeconds: unpriced.audioSeconds,
          costUsd: priced.costUsd,
          unpricedReason: priced.reason,
        ),
      );
    } catch (exception) {
      _logSink.log(
        'Cost recording failed: $exception',
        level: LogLevel.warn,
        recordingId: captureId,
      );
    }
  }

  double? _takeFallbackSeconds() {
    final double? seconds = _pendingFallbackSeconds;
    _pendingFallbackSeconds = null;
    return seconds;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/recording_usage_sink_test.dart`
Expected: PASS (8 tests)

Prove non-vacuity: temporarily change `_takeFallbackSeconds` to return `_pendingFallbackSeconds` without clearing it, run again, watch "the fallback is applied to the first chunk only" fail, then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/data/recording_usage_sink.dart test/recording_usage_sink_test.dart
git commit -m "Price each reported call and write it to the usage store"
```

---

### Task 7: scope events to a capture in `_processOne`

**Files:**
- Modify: `lib/features/recordings/presentation/recordings_controller.dart:1598-1672` (`_processOne`) and its constructor
- Modify: `lib/features/settings/presentation/settings_controller.dart:20-180` (hold the sink, pass it to the three `to…Service()` calls)
- Modify: `lib/features/recordings/presentation/recordings_page.dart:175` (build the real sink)
- Modify: `test/support/harness.dart:111-134` (`buildRecordingsController` takes the sink)
- Test: `test/cost_scoping_test.dart`

**Interfaces:**
- Consumes: `UsageSink`, `NoopUsageSink`, `UsageStage` (Task 4); `buildRecordingsController` from `test/support/harness.dart`.
- Produces: `RecordingsController` gains a `UsageSink usageSink = const NoopUsageSink()` constructor parameter and a private `static UsageStage _stageFor(CaptureType type)`; `SettingsController` gains a `UsageSink usageSink` constructor parameter (default `const NoopUsageSink()`); `buildRecordingsController` gains a `UsageSink usageSink = const NoopUsageSink()` parameter and passes it through.

- [ ] **Step 1: Extend the shared harness**

In `test/support/harness.dart`, add the parameter to `buildRecordingsController` and forward it:

```dart
  UsageSink usageSink = const NoopUsageSink(),
```

```dart
    usageSink: usageSink,
```

- [ ] **Step 2: Write the failing test**

Create `test/cost_scoping_test.dart`:

```dart
import 'dart:io';

import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records the job scope rather than the usage, so the assertions read as the
/// sequence of jobs the pipeline opened.
class _ScopeSink implements UsageSink {
  final List<String> log = <String>[];
  final List<double?> fallbacks = <double?>[];

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    log.add('begin:$captureId:${stage.name}');
    fallbacks.add(fallbackAudioSeconds);
  }

  @override
  void endJob() => log.add('end');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {}
}

class _ThrowingSink implements UsageSink {
  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) =>
      throw StateError('boom');

  @override
  void endJob() => throw StateError('boom');

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) =>
      throw StateError('boom');
}

Recording _seed({
  required String id,
  required CaptureType type,
  required int durationMs,
}) {
  return Recording(
    id: id,
    filePath: '/nonexistent/$id.bin',
    createdAt: DateTime.utc(2026, 8, 9),
    durationMs: durationMs,
    status: RecordingStatus.saved,
    type: type,
  );
}

void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('cost-scoping');
  });

  tearDown(() {
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
  });

  test('a text note opens a transcription job, then an enrichment one', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
    );

    await controller.addTextNote('a note');
    await controller.waitForProcessing();

    final String id = controller.recordings.single.id;
    expect(sink.log, <String>[
      'begin:$id:transcription',
      'end',
      'begin:$id:enrichment',
      'end',
    ]);
  });

  test('an image capture opens an ocr job, not a transcription one', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(id: 'img-1', type: CaptureType.image, durationMs: 0),
      ],
    );

    await controller.retryTranscription('img-1');
    await controller.waitForProcessing();

    expect(sink.log.first, 'begin:img-1:ocr');
  });

  test('a mic capture passes its own duration as the audio fallback', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(
          id: 'mic-1',
          type: CaptureType.audioRecording,
          durationMs: 90000,
        ),
      ],
    );

    await controller.retryTranscription('mic-1');
    await controller.waitForProcessing();

    expect(sink.fallbacks.first, closeTo(90, 1e-9));
  });

  test('an upload with durationMs 0 passes no fallback at all', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(id: 'up-1', type: CaptureType.audioUpload, durationMs: 0),
      ],
    );

    await controller.retryTranscription('up-1');
    await controller.waitForProcessing();

    // Zero is not a duration — pricing it as one would bill the upload at $0.
    expect(sink.fallbacks.first, isNull);
  });

  test('a processor that throws still closes its job', () async {
    final _ScopeSink sink = _ScopeSink();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: sink,
      seed: <Recording>[
        _seed(
          id: 'bad-1',
          type: CaptureType.audioRecording,
          durationMs: 1000,
        ),
      ],
    );

    // No transcription profile and no file on disk, so the processor throws.
    await controller.retryTranscription('bad-1');
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(
      sink.log.where((String entry) => entry == 'end').length,
      sink.log.where((String entry) => entry.startsWith('begin')).length,
    );
  });

  test('a sink that throws never costs the capture', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      usageSink: _ThrowingSink(),
    );

    await controller.addTextNote('survives');
    await controller.waitForProcessing();

    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(controller.recordings.single.transcript, 'survives');
  });
}
```

> The last test is the one that pins the `ClipboardSink` contract at the
> controller boundary, so `beginJob`/`endJob` must be called inside a guard that
> swallows — see the implementation step.

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/cost_scoping_test.dart`
Expected: FAIL — `No named parameter with the name 'usageSink'`

- [ ] **Step 4: Write minimal implementation**

In `RecordingsController`, add the constructor parameter and field:

```dart
  /// Receives per-call usage. Ambient by design — see [UsageSink]. Defaults to
  /// a no-op so the pure-Dart suites need no database.
  final UsageSink _usageSink;
```

Wrap both sink calls so a refusing sink cannot reach the pipeline — the same
`ClipboardSink` contract the clipboard and vault hand-offs follow:

```dart
  /// The sink is best-effort at this boundary too: a store that throws costs a
  /// cost row, never the capture the row was about.
  void _beginUsageJob(String id, UsageStage stage, {double? audioSeconds}) {
    try {
      _usageSink.beginJob(id, stage, fallbackAudioSeconds: audioSeconds);
    } catch (exception) {
      _logSink.log(
        'Cost scope failed to open: $exception',
        level: LogLevel.warn,
        recordingId: id,
      );
    }
  }

  void _endUsageJob() {
    try {
      _usageSink.endJob();
    } catch (_) {
      // Deliberately silent: the job is over either way.
    }
  }
```

Add the stage mapping:

```dart
  /// Which stage a capture's processor bills under. Derived from the item's
  /// type rather than asked of the processor, because `Processor` has no such
  /// question and adding one would widen a contract this design deliberately
  /// leaves alone.
  static UsageStage _stageFor(CaptureType type) => switch (type) {
    CaptureType.image => UsageStage.ocr,
    CaptureType.audioRecording ||
    CaptureType.audioUpload ||
    CaptureType.video ||
    CaptureType.text => UsageStage.transcription,
  };
```

Then wrap the two call sites in `_processOne`. Replace

```dart
        final String transcript = await processor.process(recording);
```

with

```dart
        // Scope the events this job produces to this capture. The pair is safe
        // here and only here: the drain is single-flight, so exactly one job is
        // ever open. `durationMs` is 0 on uploads, which the sink reads as "no
        // fallback" rather than as zero-length audio.
        _beginUsageJob(
          id,
          _stageFor(recording.type),
          audioSeconds:
              recording.durationMs > 0 ? recording.durationMs / 1000 : null,
        );
        final String transcript;
        try {
          transcript = await processor.process(recording);
        } finally {
          _endUsageJob();
        }
```

and wrap the enrichment call:

```dart
        _beginUsageJob(id, UsageStage.enrichment);
        try {
          await _enrich(id, transcript);
        } finally {
          _endUsageJob();
        }
```

In `SettingsController`, hold the sink and pass it into each builder:

```dart
  SettingsController({
    SettingsRepository? repository,
    UsageSink usageSink = const NoopUsageSink(),
  }) : _repository = repository ?? SettingsRepository(),
       _usageSink = usageSink;

  final UsageSink _usageSink;
```

```dart
      _service = active?.toService(usageSink: _usageSink) ??
          const DisabledTranscriptionService();
```

and the same for `toEnrichmentService` and `toOcrService`.

In `recordings_page.dart`, build the real sink once and hand it to both controllers:

```dart
    final RecordingUsageSink usageSink = RecordingUsageSink(
      repository: usageRepository,
      // Read per call so a rate edited in the Config tab reaches the next
      // capture with nothing to rebuild.
      priceBook: () => PriceBook(overrides: settings.settings.priceOverrides),
      logSink: logs,
    );
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/cost_scoping_test.dart`
Expected: PASS (6 tests)

Prove non-vacuity twice: temporarily move `_endUsageJob()` out of the `finally` and into the line after `processor.process`, run again, watch "a processor that throws still closes its job" fail, restore. Then temporarily drop the `try`/`catch` from `_beginUsageJob`, run again, watch "a sink that throws never costs the capture" fail, restore.

- [ ] **Step 6: Commit**

```bash
flutter analyze && flutter test
git add lib/features/recordings lib/features/settings/presentation/settings_controller.dart test/cost_scoping_test.dart
git commit -m "Scope usage events to the capture that produced them"
```

---

### Task 8: persist rate overrides in settings

**Files:**
- Modify: `lib/features/settings/domain/app_settings.dart`
- Modify: `lib/features/settings/presentation/settings_controller.dart` (add the two setters)
- Test: `test/price_overrides_settings_test.dart`

**Interfaces:**
- Consumes: `ModelPrice`, `StoragePrice` (Task 2).
- Produces: `AppSettings` gains `Map<String, ModelPrice> get priceOverrides`, `StoragePrice get storagePrice`, `bool get hasCustomStoragePrice`, and `copyWith` parameters `Map<String, ModelPrice>? priceOverrides, StoragePrice? storagePrice, bool clearStoragePrice`; `SettingsController` gains `Future<void> setPriceOverride(String key, ModelPrice? price)` and `Future<void> setStoragePrice(StoragePrice? price)`.

- [ ] **Step 1: Write the failing test**

Create `test/price_overrides_settings_test.dart`:

```dart
import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an untouched install writes no price keys at all', () {
    final Map<String, dynamic> json = AppSettings.empty.toJson();

    expect(json.containsKey('priceOverrides'), isFalse);
    expect(json.containsKey('storagePrice'), isFalse);
  });

  test('an untouched install reads the shipped storage defaults', () {
    expect(AppSettings.empty.storagePrice.r2PerGbMonth, 0.015);
    expect(AppSettings.empty.hasCustomStoragePrice, isFalse);
  });

  test('overrides round-trip', () {
    final AppSettings settings = AppSettings.empty.copyWith(
      priceOverrides: <String, ModelPrice>{
        'gpt-6-nova': const ModelPrice(inputPerMTok: 3, outputPerMTok: 9),
      },
      storagePrice: const StoragePrice(
        r2PerGbMonth: 0.02,
        tursoPerGbMonth: 0.75,
      ),
    );

    final AppSettings restored = AppSettings.fromJson(settings.toJson());

    expect(restored.priceOverrides['gpt-6-nova']?.inputPerMTok, 3);
    expect(restored.storagePrice.tursoPerGbMonth, 0.75);
    expect(restored.hasCustomStoragePrice, isTrue);
  });

  test('a stored storage price of zero survives, unlike an absent one', () {
    final AppSettings settings = AppSettings.empty.copyWith(
      storagePrice: const StoragePrice(r2PerGbMonth: 0, tursoPerGbMonth: 0),
    );

    final AppSettings restored = AppSettings.fromJson(settings.toJson());

    expect(restored.storagePrice.r2PerGbMonth, 0);
    expect(restored.hasCustomStoragePrice, isTrue);
  });

  test('an unreadable override row is dropped, not fatal', () {
    final AppSettings restored = AppSettings.fromJson(<String, dynamic>{
      'priceOverrides': <String, dynamic>{
        'good': <String, dynamic>{'inputPerMTok': 1},
        'bad': 'not an object',
      },
    });

    expect(restored.priceOverrides.keys, <String>['good']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/price_overrides_settings_test.dart`
Expected: FAIL — `The getter 'priceOverrides' isn't defined for the class 'AppSettings'`

- [ ] **Step 3: Write minimal implementation**

Add to `AppSettings` the constructor parameters `this.priceOverrides = const <String, ModelPrice>{}` and `StoragePrice? storagePrice` (stored privately), the fields:

```dart
  /// **Only what the user changed.** The shipped table lives in
  /// `PriceBookDefaults`, so a later build can correct a provider's price for
  /// everyone who never edited it. Written to disk only when non-empty.
  final Map<String, ModelPrice> priceOverrides;

  /// Private and nullable for the same reason `_shortcuts` is: absent means
  /// "never configured, use the shipped defaults", while present is
  /// authoritative *including a deliberate zero*.
  final StoragePrice? _storagePrice;

  StoragePrice get storagePrice => _storagePrice ?? StoragePrice.defaults;

  bool get hasCustomStoragePrice => _storagePrice != null;
```

In `toJson`, write both keys conditionally:

```dart
      if (priceOverrides.isNotEmpty)
        'priceOverrides': <String, dynamic>{
          for (final MapEntry<String, ModelPrice> entry
              in priceOverrides.entries)
            entry.key: entry.value.toJson(),
        },
      if (_storagePrice != null) 'storagePrice': _storagePrice.toJson(),
```

In `fromJson`, read them defensively:

```dart
    final dynamic rawPrices = json['priceOverrides'];
    final Map<String, ModelPrice> priceOverrides = <String, ModelPrice>{};
    if (rawPrices is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in rawPrices.entries) {
        final dynamic value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        priceOverrides[entry.key] = ModelPrice.fromJson(value);
      }
    }

    final dynamic rawStorage = json['storagePrice'];
    final StoragePrice? storagePrice = rawStorage is Map<String, dynamic>
        ? StoragePrice.fromJson(rawStorage)
        : null;
```

In `copyWith`, fall back to the **raw** field rather than the getter, so an unrelated save never promotes an untouched install to a custom one:

```dart
      storagePrice: clearStoragePrice ? null : (storagePrice ?? _storagePrice),
```

Then add the two `SettingsController` setters, each following the existing save-and-notify shape; `setPriceOverride(key, null)` (and a `ModelPrice` whose `isEmpty` is true) removes the key rather than storing a blank entry.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/price_overrides_settings_test.dart`
Expected: PASS (5 tests)

Prove non-vacuity: temporarily make `copyWith` pass `storagePrice ?? this.storagePrice` (the getter), run the full suite, watch "an untouched install writes no price keys at all" fail once any other setting is saved — then restore.

- [ ] **Step 5: Commit**

```bash
flutter analyze && flutter test
git add lib/features/settings test/price_overrides_settings_test.dart
git commit -m "Persist rate overrides without freezing the shipped price table"
```

---

### Task 9: the Config tab's `PRICING` section

**Files:**
- Create: `lib/features/costs/presentation/pricing_section.dart`
- Modify: `lib/features/settings/presentation/config_tab.dart` (insert above the `STORAGE` section at line 444)
- Test: `test/widget/pricing_section_test.dart`

**Interfaces:**
- Consumes: `PriceBook`, `PriceBookDefaults`, `ModelPrice`, `StoragePrice` (Task 2); `UsageRepository` (Task 3); `SectionHeader`, `ConsoleCard`, `InfoRow`, `ConsoleField`, `ConsoleText`, `Console`, `formatBytes` from `lib/app/ui_kit.dart`.
- Produces: `String formatUsd(double)` added to `lib/app/ui_kit.dart` beside `formatBytes` (Task 10's card line needs it too, and `card_parts.dart` must not import a `costs/presentation/` file); `class PricingSection extends StatefulWidget` — **stateful**, because each rate row owns a `TextEditingController` seeded from the price book — with a plain constructor (it paints palette colours, so **no `const`**) taking `{required double thisMonthUsd, required double allTimeUsd, required int storageBytes, required StoragePrice storagePrice, required List<String> models, required PriceBook priceBook, required Map<String, int> missingRateCounts, required int unknownQuantityCount, required DateTime verifiedOn, required void Function(String key, ModelPrice? price) onRateChanged}`.

- [ ] **Step 1: Write the failing test**

Create `test/widget/pricing_section_test.dart`:

```dart
import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/presentation/pricing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

PricingSection _section({
  Map<String, int> missingRateCounts = const <String, int>{},
  int unknownQuantityCount = 0,
  void Function(String, ModelPrice?)? onRateChanged,
}) {
  return PricingSection(
    thisMonthUsd: 1.24,
    allTimeUsd: 8.90,
    storageBytes: 2254857830,
    storagePrice: StoragePrice.defaults,
    models: const <String>['gpt-transcribe', 'gpt-5.6-luna'],
    priceBook: const PriceBook(),
    missingRateCounts: missingRateCounts,
    unknownQuantityCount: unknownQuantityCount,
    verifiedOn: DateTime.utc(2026, 8, 9),
    onRateChanged: onRateChanged ?? (String _, ModelPrice? __) {},
  );
}

void main() {
  testWidgets('reports the month, the all-time total and the storage rate', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.textContaining('\$1.24'), findsOneWidget);
    expect(find.textContaining('\$8.90'), findsOneWidget);
    expect(find.textContaining('/mo'), findsOneWidget);
  });

  testWidgets('lists only the models in use', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.text('gpt-transcribe'), findsOneWidget);
    expect(find.text('claude-opus-5'), findsNothing);
  });

  testWidgets('prints the date the shipped rates were verified', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();

    expect(find.textContaining('2026-08-09'), findsOneWidget);
  });

  testWidgets('MISSING RATES appears only when a rate is missing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section()));
    await tester.pump();
    expect(find.text('MISSING RATES'), findsNothing);

    await tester.pumpWidget(
      _host(_section(missingRateCounts: <String, int>{'gpt-6-nova': 3})),
    );
    await tester.pump();

    expect(find.text('MISSING RATES'), findsOneWidget);
    expect(find.textContaining('gpt-6-nova'), findsOneWidget);
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('an unknown-quantity count is reported apart from MISSING RATES', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_section(unknownQuantityCount: 2)));
    await tester.pump();

    // No rate would price these, so they must not appear under the control
    // that offers one.
    expect(find.text('MISSING RATES'), findsNothing);
    expect(find.textContaining('unknown audio duration'), findsOneWidget);
  });

  testWidgets('editing a rate reports the new value', (
    WidgetTester tester,
  ) async {
    final List<String> edits = <String>[];
    await tester.pumpWidget(
      _host(
        _section(
          onRateChanged: (String key, ModelPrice? price) =>
              edits.add('$key:${price?.inputPerMTok}'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '0.42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(edits.single, startsWith('gpt-transcribe:'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/pricing_section_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../pricing_section.dart'`

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/costs/presentation/pricing_section.dart` with a `PricingSection` that renders, in order:

1. `SectionHeader(title: 'PRICING')`.
2. A `ConsoleCard` whose first child is an `InfoRow(label: 'THIS MONTH', value: formatUsd(thisMonthUsd))`, then `InfoRow(label: 'ALL TIME', …)`, then `InfoRow(label: 'STORAGE', value: '${formatBytes(storageBytes)} ≈ ${formatUsd(storageMonthlyUsd)}/mo')` where `storageMonthlyUsd = storageBytes / 1073741824 * (storagePrice.r2PerGbMonth + storagePrice.tursoPerGbMonth)`.
3. One editable row per entry of `models`, each showing the model name plus two `ConsoleField`s (input / output per MTok) for a chat model or one (per audio minute) for a transcription model, seeded from `priceBook.lookup(...)`. A submitted field calls `onRateChanged(key, price)`; a row whose value differs from `PriceBookDefaults.rates[key]` shows a `custom` marker and a reset control that calls `onRateChanged(key, null)`.
4. `Text('defaults verified ${verifiedOn.toIso8601String().substring(0, 10)}', style: ConsoleText.micro)`.
5. `if (missingRateCounts.isNotEmpty)` a `MISSING RATES` block, one row per entry: the key and its call count, with the same rate fields.
6. `if (unknownQuantityCount > 0)` a single line: `'$unknownQuantityCount call(s) with unknown audio duration — no rate can price these'`.

Add the shared formatter to `lib/app/ui_kit.dart`, directly below `formatBytes` — `card_parts.dart` needs it in Task 10 and must not reach into a `costs/presentation/` file:

```dart
/// Four decimals, because a single enrichment call routinely costs less than a
/// tenth of a cent and rounding it to `$0.00` would make the readout useless.
String formatUsd(double value) => '\$${value.toStringAsFixed(4)}';
```

Every widget in this file takes a plain constructor — it paints `Console` colours, and a `const` one would keep painting the previous palette after a theme swap (`test/theme_test.dart` enforces this).

Wire it into `config_tab.dart` immediately above `SectionHeader(title: 'STORAGE')`, with `const SizedBox(height: 22)` between the two, following the surrounding style. Default `models`, `missingRateCounts` and `unknownQuantityCount` to empty at the `ConfigTab` call site so a widget test never touches the real database — the same rule `EnrichmentContextSection` follows for the project list.

**Wire the backfill at the shell, not in the section.** `PricingSection` only reports the edit; the `ConfigTab` host handles it, so that persisting a rate and repricing the rows it unblocks stay one action:

```dart
  onRateChanged: (String key, ModelPrice? price) async {
    await settings.setPriceOverride(key, price);
    if (price == null) return;
    // Only rows that were never priced can change — see UsageRepository.backfill.
    final int filled = usageRepository.backfill(
      key,
      PriceBook(overrides: settings.settings.priceOverrides),
    );
    if (filled > 0) setState(() {});
  },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/pricing_section_test.dart`
Expected: PASS (6 tests)

Prove non-vacuity: temporarily fold `unknownQuantityCount` into `missingRateCounts`, run again, watch "an unknown-quantity count is reported apart from MISSING RATES" fail, then restore.

- [ ] **Step 5: Run the app and look at the section**

```bash
flutter build macos --release && open "build/macos/Build/Products/Release/Augustyniak Capture.app"
```

Open the Config tab, scroll to `PRICING`, and check both themes via `APPEARANCE`. A green suite does not prove a layout reads correctly — the light theme once shipped analyze-clean, 475 tests green and visibly broken.

- [ ] **Step 6: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/presentation/pricing_section.dart lib/features/settings/presentation/config_tab.dart test/widget/pricing_section_test.dart
git commit -m "Edit provider rates and read totals in the Config tab"
```

---

### Task 10: cost on the queue card and in the editor

**Files:**
- Modify: `lib/features/recordings/presentation/card_parts.dart:113-142` (`VerificationLine`)
- Create: `lib/features/costs/presentation/cost_section.dart`
- Modify: `lib/features/recordings/presentation/recording_editor.dart` (add the section below `RevisionHistorySection`)
- Test: `test/widget/cost_readout_test.dart`

**Interfaces:**
- Consumes: `UsageEvent`, `UsageStage`, `UnpricedReason` (Task 1); `formatUsd` and `formatBytes` from `lib/app/ui_kit.dart` (Task 9 added the former); `StoragePrice` (Task 2).
- Produces: `VerificationLine` gains `{double? costUsd}` and **loses its `const` constructor**; `class CostSection extends StatelessWidget` with `{required List<UsageEvent> events, required int sizeBytes, required StoragePrice storagePrice}`.

- [ ] **Step 1: Write the failing test**

Create `test/widget/cost_readout_test.dart`:

```dart
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/presentation/cost_section.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Recording _recording() => Recording(
  id: 'cap-1',
  filePath: '/tmp/cap-1.m4a',
  createdAt: DateTime.utc(2026, 8, 9),
  durationMs: 90000,
  sizeBytes: 7130316,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
);

void main() {
  testWidgets('the verification line prints the cost when there is one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(VerificationLine(recording: _recording(), costUsd: 0.0021)),
    );
    await tester.pump();

    expect(find.textContaining('file verified'), findsOneWidget);
    expect(find.textContaining('\$0.0021'), findsOneWidget);
  });

  testWidgets('a capture with no events prints a dash, not a zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(VerificationLine(recording: _recording(), costUsd: null)),
    );
    await tester.pump();

    expect(find.textContaining('cost —'), findsOneWidget);
    expect(find.textContaining('\$0.0000'), findsNothing);
  });

  testWidgets('the cost section lists one row per event', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: CostSection(
            sizeBytes: 7130316,
            storagePrice: StoragePrice.defaults,
            events: <UsageEvent>[
              UsageEvent(
                id: 'e1',
                captureId: 'cap-1',
                stage: UsageStage.transcription,
                provider: 'api.openai.com',
                model: 'gpt-transcribe',
                at: DateTime.utc(2026, 8, 9),
                audioSeconds: 90,
                costUsd: 0.00675,
              ),
              UsageEvent(
                id: 'e2',
                captureId: 'cap-1',
                stage: UsageStage.enrichment,
                provider: 'api.openai.com',
                model: 'gpt-5.6-luna',
                at: DateTime.utc(2026, 8, 9),
                inputTokens: 1200,
                outputTokens: 90,
                costUsd: 0.000348,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('TRANSCRIPTION'), findsOneWidget);
    expect(find.textContaining('ENRICHMENT'), findsOneWidget);
    expect(find.textContaining('gpt-transcribe'), findsOneWidget);
    expect(find.textContaining('1 200 in'), findsOneWidget);
  });

  testWidgets('an unpriced event says why rather than showing zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        CostSection(
          sizeBytes: 0,
          storagePrice: StoragePrice.defaults,
          events: <UsageEvent>[
            UsageEvent(
              id: 'e1',
              captureId: 'cap-1',
              stage: UsageStage.transcription,
              provider: 'api.openai.com',
              model: 'gpt-transcribe',
              at: DateTime.utc(2026, 8, 9),
              unpricedReason: UnpricedReason.noQuantity,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('unknown duration'), findsOneWidget);
    expect(find.textContaining('\$0.0000'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/cost_readout_test.dart`
Expected: FAIL — `No named parameter with the name 'costUsd'`

- [ ] **Step 3: Write minimal implementation**

Change `VerificationLine` — note the dropped `const`:

```dart
class VerificationLine extends StatelessWidget {
  // Not `const`: this widget paints `Console.green`, and a const constructor
  // would keep painting the previous palette after a theme swap — a stale frame
  // no widget test can see. See the theme rule in CLAUDE.md.
  VerificationLine({super.key, required this.recording, this.costUsd});

  final Recording recording;

  /// Sum of the capture's usage events. Null means no event exists yet, which
  /// the line reports as `cost —` rather than as zero.
  final double? costUsd;

  @override
  Widget build(BuildContext context) {
    final String? size = formatBytes(recording.sizeBytes);
    final String text = <String>[
      'file verified',
      ?size,
      costUsd == null ? 'cost —' : formatUsd(costUsd!),
      'persisted',
    ].join(' · ');
    // …unchanged Row below…
  }
}
```

Every call site of `VerificationLine` must drop its `const` too — `flutter analyze` names each one.

Create `lib/features/costs/presentation/cost_section.dart` with a collapsed `COST` section built the same way `RevisionHistorySection` is: a header row that toggles, then one line per event reading `${event.stage.label} · ${event.model} · <quantities> · <amount>`, where quantities are `'${inputTokens} in / ${outputTokens} out'` for a chat stage and `'${audioSeconds.round()} s'` for transcription, and the amount is `formatUsd(costUsd)` or the reason (`'no rate'` / `'unknown duration'`). The last line reports storage: `'${formatBytes(sizeBytes)} · ${formatUsd(monthly)}/mo'`.

Insert it into `RecordingEditor` directly below `RevisionHistorySection`, taking its events from the same repository the shell already holds.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/cost_readout_test.dart`
Expected: PASS (4 tests)

Prove non-vacuity: temporarily render `formatUsd(costUsd ?? 0)` on the verification line, run again, watch "a capture with no events prints a dash, not a zero" fail, then restore.

- [ ] **Step 5: Run the app and look at a real queue**

```bash
flutter build macos --release && open "build/macos/Build/Products/Release/Augustyniak Capture.app"
```

Record something, let it process, and read the card line and the editor's `COST` section in both themes. Confirm the row height did not change and that a legacy capture (no events) reads `cost —` rather than `$0.0000`.

- [ ] **Step 6: Commit**

```bash
flutter analyze && flutter test
git add lib/features/costs/presentation/cost_section.dart lib/features/recordings/presentation test/widget/cost_readout_test.dart
git commit -m "Show what each capture cost on the card and in the editor"
```

---

## Out of scope

Deliberately not built here, and worth their own decisions later:

- **Turso sync of `usage_events`.** The table is local only; a second device records its own costs.
- **Measuring audio duration at import.** `MediaImporter` writes `durationMs: 0` for every upload, so an uploaded audio file transcribed on a `gpt-*-transcribe` model records `noQuantity`. Probing duration at import (native media metadata on mobile, `ffprobe` on desktop) would close the last gap; the Config tab reports the count in the meantime so the gap is visible rather than silent.
- **Budgets and alerts**, and **CSV export**.

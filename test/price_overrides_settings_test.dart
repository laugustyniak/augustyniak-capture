import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
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

  test(
    'an unrelated save must not turn an untouched install into a custom '
    'storage price',
    () {
      // Mirrors the equivalent guard for enrichmentInstructions in
      // settings_test.dart: copyWith must fall back to the raw private field,
      // never the public getter, or saving an unrelated setting (here: the
      // audio config) would silently promote every untouched install to a
      // custom storage price the moment anything else changes.
      final AppSettings promoted = AppSettings.empty.copyWith(
        audio: const AudioConfig(sampleRate: 22050),
      );

      expect(promoted.hasCustomStoragePrice, isFalse);
      expect(promoted.toJson().containsKey('storagePrice'), isFalse);
    },
  );

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

import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_model_keys.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';

UsageEvent _event({
  String model = 'gpt-transcribe',
  String provider = 'api.openai.com',
}) {
  return UsageEvent(
    id: 'e',
    captureId: 'c',
    stage: UsageStage.transcription,
    provider: provider,
    model: model,
    at: DateTime.utc(2026, 8, 9),
  );
}

ProviderProfile _profile({
  String id = 'p1',
  String name = 'OpenAI Whisper',
  String endpoint = 'https://api.openai.com/v1/audio/transcriptions',
  String? model = 'gpt-transcribe',
  ProfileKind kind = ProfileKind.transcription,
}) {
  return ProviderProfile(
    id: id,
    name: name,
    endpoint: endpoint,
    kind: kind,
    model: model,
  );
}

void main() {
  group('usageModelKeys', () {
    test('is empty with no events and no profiles', () {
      expect(
        usageModelKeys(events: const <UsageEvent>[], profiles: const <ProviderProfile>[]),
        isEmpty,
      );
    });

    test('includes a key from history alone', () {
      expect(
        usageModelKeys(
          events: <UsageEvent>[_event(model: 'gpt-transcribe')],
          profiles: const <ProviderProfile>[],
        ),
        <String>['gpt-transcribe'],
      );
    });

    // This is I5's whole point: an install with an active profile and no
    // usage history yet (no API call has ever landed) must still get an
    // editable rate row and a chance to see MISSING RATES before paying for
    // a call on a model outside the shipped table — the failure mode
    // observed live, where the PRICING section rendered no rows at all.
    test('includes a key from a profile alone, with no usage history', () {
      expect(
        usageModelKeys(
          events: const <UsageEvent>[],
          profiles: <ProviderProfile>[_profile(model: 'gpt-transcribe')],
        ),
        <String>['gpt-transcribe'],
      );
    });

    test('unions history and profile keys, de-duplicating and sorting', () {
      expect(
        usageModelKeys(
          events: <UsageEvent>[_event(model: 'gpt-transcribe')],
          profiles: <ProviderProfile>[
            _profile(model: 'gpt-transcribe'),
            _profile(id: 'p2', model: 'claude-sonnet-5', kind: ProfileKind.enrichment),
          ],
        ),
        <String>['claude-sonnet-5', 'gpt-transcribe'],
      );
    });

    // Same blank-model-falls-back-to-provider-name rule PriceBook.keyFor
    // applies to a usage event must also apply on the profile side, or a
    // local server profile with no model set would key differently here
    // than the events it eventually produces.
    test('a profile with no model set keys by its host, like PriceBook.keyFor', () {
      expect(
        usageModelKeys(
          events: const <UsageEvent>[],
          profiles: <ProviderProfile>[
            _profile(
              endpoint: 'http://localhost:8080/v1/audio/transcriptions',
              model: null,
            ),
          ],
        ),
        <String>['localhost'],
      );
    });
  });
}

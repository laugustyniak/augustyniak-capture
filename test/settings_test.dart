import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/settings/data/settings_repository.dart';
import 'package:voice_notes_phase1/features/settings/domain/app_settings.dart';
import 'package:voice_notes_phase1/features/settings/domain/audio_config.dart';
import 'package:voice_notes_phase1/features/settings/domain/provider_profile.dart';
import 'package:voice_notes_phase1/features/settings/presentation/settings_controller.dart';
import 'package:voice_notes_phase1/features/transcription/data/transcription_service.dart';

/// In-memory stand-in so controller tests need no path_provider bindings.
/// Extends the real repository and overrides only the IO methods, so
/// `settingsFile()` (which touches path_provider) is never reached.
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? stored;
  int saveCount = 0;

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async {
    stored = settings;
    saveCount++;
  }
}

void main() {
  group('ProviderProfile', () {
    test('JSON round-trip preserves every field', () {
      const ProviderProfile original = ProviderProfile(
        id: 'p1',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
        language: 'pl',
        bearerToken: 'sk-secret',
      );

      final ProviderProfile restored =
          ProviderProfile.fromJson(original.toJson());

      expect(restored.id, 'p1');
      expect(restored.name, 'OpenAI');
      expect(restored.endpoint, original.endpoint);
      expect(restored.model, 'whisper-1');
      expect(restored.language, 'pl');
      expect(restored.bearerToken, 'sk-secret');
    });

    test('fromJson defaults name and endpoint when absent', () {
      final ProviderProfile restored =
          ProviderProfile.fromJson(<String, dynamic>{'id': 'x'});

      expect(restored.id, 'x');
      expect(restored.name, 'Profile');
      expect(restored.endpoint, '');
      expect(restored.hasEndpoint, isFalse);
    });

    test('host extracts the domain from the endpoint', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'Groq',
        endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      expect(profile.host, 'api.groq.com');
    });

    test('toService returns a configured HTTP service for a valid endpoint', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
      );
      expect(profile.toService(), isA<HttpWhisperTranscriptionService>());
    });

    test('toService degrades to disabled for a blank or schemeless endpoint',
        () {
      const ProviderProfile blank =
          ProviderProfile(id: 'p', name: 'x', endpoint: '');
      const ProviderProfile schemeless =
          ProviderProfile(id: 'q', name: 'y', endpoint: 'not-a-url');

      expect(blank.toService(), isA<DisabledTranscriptionService>());
      expect(schemeless.toService(), isA<DisabledTranscriptionService>());
    });

    test('copyWith can clear nullable fields', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'x',
        endpoint: 'https://h/e',
        model: 'm',
        bearerToken: 't',
      );
      final ProviderProfile cleared =
          profile.copyWith(clearModel: true, clearBearerToken: true);

      expect(cleared.model, isNull);
      expect(cleared.bearerToken, isNull);
      expect(cleared.endpoint, 'https://h/e');
    });
  });

  group('AudioConfig', () {
    test('JSON round-trip', () {
      const AudioConfig original =
          AudioConfig(sampleRate: 44100, numChannels: 2, bitRate: 128000);
      final AudioConfig restored = AudioConfig.fromJson(original.toJson());

      expect(restored, original);
      expect(restored.isMono, isFalse);
    });

    test('fromJson defaults every field on empty JSON', () {
      final AudioConfig restored = AudioConfig.fromJson(<String, dynamic>{});
      expect(restored, AudioConfig.defaults);
      expect(restored.sampleRate, 16000);
      expect(restored.isMono, isTrue);
    });

    test('value equality and hashCode', () {
      const AudioConfig a = AudioConfig(sampleRate: 16000);
      const AudioConfig b = AudioConfig(sampleRate: 16000);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('AppSettings', () {
    test('JSON round-trip preserves profiles, active id and audio', () {
      const AppSettings original = AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(id: 'p1', name: 'A', endpoint: 'https://a/e'),
          ProviderProfile(id: 'p2', name: 'B', endpoint: 'https://b/e'),
        ],
        activeProfileId: 'p2',
        audio: AudioConfig(sampleRate: 22050),
      );

      final AppSettings restored = AppSettings.fromJson(original.toJson());

      expect(restored.profiles, hasLength(2));
      expect(restored.activeProfileId, 'p2');
      expect(restored.audio.sampleRate, 22050);
    });

    test('fromJson defaults every field on legacy/partial JSON', () {
      final AppSettings restored =
          AppSettings.fromJson(<String, dynamic>{'activeProfileId': null});

      expect(restored.profiles, isEmpty);
      expect(restored.activeProfileId, isNull);
      expect(restored.audio, AudioConfig.defaults);
    });

    test('activeProfile is null when the active id dangles', () {
      const AppSettings settings = AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(id: 'p1', name: 'A', endpoint: 'https://a/e'),
        ],
        activeProfileId: 'gone',
      );
      expect(settings.activeProfile, isNull);
    });

    test('activeProfile resolves the matching profile', () {
      const AppSettings settings = AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(id: 'p1', name: 'A', endpoint: 'https://a/e'),
        ],
        activeProfileId: 'p1',
      );
      expect(settings.activeProfile?.name, 'A');
    });
  });

  group('SettingsController', () {
    test('addProfile activates the first profile and persists', () async {
      final _FakeSettingsRepository repo = _FakeSettingsRepository();
      final SettingsController controller =
          SettingsController(repository: repo);
      await controller.initialize();

      final ProviderProfile added = await controller.addProfile(
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'sk',
      );

      expect(controller.profiles, hasLength(1));
      expect(controller.activeProfile?.id, added.id);
      expect(controller.transcriptionService,
          isA<HttpWhisperTranscriptionService>());
      expect(repo.saveCount, greaterThan(0));
    });

    test('deleting the active profile falls back to a remaining one', () async {
      final SettingsController controller =
          SettingsController(repository: _FakeSettingsRepository());
      await controller.initialize();

      final ProviderProfile first = await controller.addProfile(
          name: 'A', endpoint: 'https://a/e');
      final ProviderProfile second = await controller.addProfile(
          name: 'B', endpoint: 'https://b/e');
      expect(controller.activeProfile?.id, second.id);

      await controller.deleteProfile(second.id);

      expect(controller.profiles, hasLength(1));
      expect(controller.activeProfile?.id, first.id);
    });

    test('deleting the only profile clears the active id and disables service',
        () async {
      final SettingsController controller =
          SettingsController(repository: _FakeSettingsRepository());
      await controller.initialize();

      final ProviderProfile only = await controller.addProfile(
          name: 'A', endpoint: 'https://a/e');
      await controller.deleteProfile(only.id);

      expect(controller.profiles, isEmpty);
      expect(controller.activeProfile, isNull);
      expect(controller.transcriptionService,
          isA<DisabledTranscriptionService>());
    });

    test('updateAudio then resetAudio round-trips back to defaults', () async {
      final SettingsController controller =
          SettingsController(repository: _FakeSettingsRepository());
      await controller.initialize();

      await controller.updateAudio(
          const AudioConfig(sampleRate: 44100, bitRate: 128000));
      expect(controller.audio.sampleRate, 44100);

      await controller.resetAudio();
      expect(controller.audio, AudioConfig.defaults);
    });

    test('reuses the same service until the active profile changes', () async {
      final SettingsController controller =
          SettingsController(repository: _FakeSettingsRepository());
      await controller.initialize();
      final ProviderProfile profile = await controller.addProfile(
          name: 'A', endpoint: 'https://a/e');

      final TranscriptionService first = controller.transcriptionService;
      // Unrelated change: must not spawn a new service (and a new http.Client).
      await controller.updateAudio(const AudioConfig(sampleRate: 44100));
      expect(identical(controller.transcriptionService, first), isTrue);

      await controller
          .updateProfile(profile.copyWith(endpoint: 'https://b/e'));
      expect(identical(controller.transcriptionService, first), isFalse);
    });

    test('setActiveProfile(null) disables transcription', () async {
      final SettingsController controller =
          SettingsController(repository: _FakeSettingsRepository());
      await controller.initialize();
      await controller.addProfile(name: 'A', endpoint: 'https://a/e');

      await controller.setActiveProfile(null);

      expect(controller.activeProfile, isNull);
      expect(controller.transcriptionService,
          isA<DisabledTranscriptionService>());
    });
  });
}

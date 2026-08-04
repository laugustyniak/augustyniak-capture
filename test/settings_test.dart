import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/data/settings_repository.dart';
import 'package:audivoa_core/features/settings/domain/app_settings.dart';
import 'package:audivoa_core/features/settings/domain/audio_config.dart';
import 'package:audivoa_core/features/settings/domain/provider_profile.dart';
import 'package:audivoa_core/features/settings/presentation/settings_controller.dart';
import 'package:audivoa_core/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:audivoa_core/features/enrichment/domain/enrichment_service.dart';
import 'package:audivoa_core/features/processing/data/http_vision_ocr_service.dart';
import 'package:audivoa_core/features/processing/data/ocr_service.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

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

      final ProviderProfile restored = ProviderProfile.fromJson(
        original.toJson(),
      );

      expect(restored.id, 'p1');
      expect(restored.name, 'OpenAI');
      expect(restored.endpoint, original.endpoint);
      expect(restored.model, 'whisper-1');
      expect(restored.language, 'pl');
      expect(restored.bearerToken, 'sk-secret');
    });

    test('fromJson defaults name and endpoint when absent', () {
      final ProviderProfile restored = ProviderProfile.fromJson(
        <String, dynamic>{'id': 'x'},
      );

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

    test(
      'toService returns a configured HTTP service for a valid endpoint',
      () {
        const ProviderProfile profile = ProviderProfile(
          id: 'p',
          name: 'OpenAI',
          endpoint: 'https://api.openai.com/v1/audio/transcriptions',
          model: 'whisper-1',
        );
        expect(profile.toService(), isA<HttpWhisperTranscriptionService>());
      },
    );

    test(
      'toService degrades to disabled for a blank or schemeless endpoint',
      () {
        const ProviderProfile blank = ProviderProfile(
          id: 'p',
          name: 'x',
          endpoint: '',
        );
        const ProviderProfile schemeless = ProviderProfile(
          id: 'q',
          name: 'y',
          endpoint: 'not-a-url',
        );

        expect(blank.toService(), isA<DisabledTranscriptionService>());
        expect(schemeless.toService(), isA<DisabledTranscriptionService>());
      },
    );

    test('copyWith can clear nullable fields', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'x',
        endpoint: 'https://h/e',
        model: 'm',
        bearerToken: 't',
      );
      final ProviderProfile cleared = profile.copyWith(
        clearModel: true,
        clearBearerToken: true,
      );

      expect(cleared.model, isNull);
      expect(cleared.bearerToken, isNull);
      expect(cleared.endpoint, 'https://h/e');
    });
  });

  group('AudioConfig', () {
    test('JSON round-trip', () {
      const AudioConfig original = AudioConfig(
        sampleRate: 44100,
        numChannels: 2,
        bitRate: 128000,
      );
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
      final AppSettings restored = AppSettings.fromJson(<String, dynamic>{
        'activeProfileId': null,
      });

      expect(restored.profiles, isEmpty);
      expect(restored.activeProfileId, isNull);
      expect(restored.audio, AudioConfig.defaults);
    });

    test('enrichmentInstructions round-trip, and legacy files have none', () {
      const AppSettings original = AppSettings(
        enrichmentInstructions: 'I collect specs and meeting notes.',
      );

      expect(
        AppSettings.fromJson(original.toJson()).enrichmentInstructions,
        'I collect specs and meeting notes.',
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{}).enrichmentInstructions,
        isNull,
      );
      // A hand-edited file holding the wrong type must not take the rest of
      // settings.json down with it — same rule as the id fields.
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'enrichmentInstructions': 42,
        }).enrichmentInstructions,
        isNull,
      );
    });

    test('clearing the instructions survives copyWith', () {
      const AppSettings settings = AppSettings(enrichmentInstructions: 'x');

      expect(
        settings
            .copyWith(clearEnrichmentInstructions: true)
            .enrichmentInstructions,
        isNull,
      );
      expect(settings.copyWith().enrichmentInstructions, 'x');
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
      final SettingsController controller = SettingsController(
        repository: repo,
      );
      await controller.initialize();

      final ProviderProfile added = await controller.addProfile(
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'sk',
      );

      expect(controller.profiles, hasLength(1));
      expect(controller.activeProfile?.id, added.id);
      expect(
        controller.transcriptionService,
        isA<HttpWhisperTranscriptionService>(),
      );
      expect(repo.saveCount, greaterThan(0));
    });

    test('deleting the active profile falls back to a remaining one', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();

      final ProviderProfile first = await controller.addProfile(
        name: 'A',
        endpoint: 'https://a/e',
      );
      final ProviderProfile second = await controller.addProfile(
        name: 'B',
        endpoint: 'https://b/e',
      );
      expect(controller.activeProfile?.id, second.id);

      await controller.deleteProfile(second.id);

      expect(controller.profiles, hasLength(1));
      expect(controller.activeProfile?.id, first.id);
    });

    test(
      'deleting the only profile clears the active id and disables service',
      () async {
        final SettingsController controller = SettingsController(
          repository: _FakeSettingsRepository(),
        );
        await controller.initialize();

        final ProviderProfile only = await controller.addProfile(
          name: 'A',
          endpoint: 'https://a/e',
        );
        await controller.deleteProfile(only.id);

        expect(controller.profiles, isEmpty);
        expect(controller.activeProfile, isNull);
        expect(
          controller.transcriptionService,
          isA<DisabledTranscriptionService>(),
        );
      },
    );

    test('setEnrichmentInstructions trims, and blank clears it', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();

      await controller.setEnrichmentInstructions('  I collect specs.  ');
      expect(controller.enrichmentInstructions, 'I collect specs.');

      await controller.setEnrichmentInstructions('   ');
      expect(controller.enrichmentInstructions, isNull);
    });

    test('updateAudio then resetAudio round-trips back to defaults', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();

      await controller.updateAudio(
        const AudioConfig(sampleRate: 44100, bitRate: 128000),
      );
      expect(controller.audio.sampleRate, 44100);

      await controller.resetAudio();
      expect(controller.audio, AudioConfig.defaults);
    });

    test('reuses the same service until the active profile changes', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();
      final ProviderProfile profile = await controller.addProfile(
        name: 'A',
        endpoint: 'https://a/e',
      );

      final TranscriptionService first = controller.transcriptionService;
      // Unrelated change: must not spawn a new service (and a new http.Client).
      await controller.updateAudio(const AudioConfig(sampleRate: 44100));
      expect(identical(controller.transcriptionService, first), isTrue);

      await controller.updateProfile(profile.copyWith(endpoint: 'https://b/e'));
      expect(identical(controller.transcriptionService, first), isFalse);
    });

    test('setActiveProfile(null) disables transcription', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();
      await controller.addProfile(name: 'A', endpoint: 'https://a/e');

      await controller.setActiveProfile(null);

      expect(controller.activeProfile, isNull);
      expect(
        controller.transcriptionService,
        isA<DisabledTranscriptionService>(),
      );
    });
  });

  group('enrichment profiles', () {
    test('a legacy profile row defaults to the transcription kind', () {
      final ProviderProfile restored =
          ProviderProfile.fromJson(<String, dynamic>{
            'id': 'p1',
            'name': 'Whisper',
            'endpoint': 'https://api.openai.com/v1/audio/transcriptions',
          });

      expect(restored.kind, ProfileKind.transcription);
    });

    test('kind round-trips, and an unknown kind degrades to transcription', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p2',
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
      );

      expect(
        ProviderProfile.fromJson(profile.toJson()).kind,
        ProfileKind.enrichment,
      );
      expect(ProfileKind.fromName('embedding'), ProfileKind.transcription);
      expect(ProfileKind.fromName(null), ProfileKind.transcription);
    });

    test('toEnrichmentService degrades on a blank or schemeless endpoint', () {
      const ProviderProfile blank = ProviderProfile(
        id: 'x',
        name: 'x',
        endpoint: '  ',
      );
      const ProviderProfile schemeless = ProviderProfile(
        id: 'y',
        name: 'y',
        endpoint: 'api.example.com/v1',
      );
      const ProviderProfile usable = ProviderProfile(
        id: 'z',
        name: 'z',
        endpoint: 'https://api.example.com/v1/chat/completions',
      );

      expect(blank.toEnrichmentService(), isA<DisabledEnrichmentService>());
      expect(
        schemeless.toEnrichmentService(),
        isA<DisabledEnrichmentService>(),
      );
      expect(usable.toEnrichmentService(), isA<HttpChatEnrichmentService>());
    });

    test('activeEnrichmentProfile is null for a dangling id', () {
      const AppSettings settings = AppSettings(
        profiles: <ProviderProfile>[],
        activeEnrichmentProfileId: 'gone',
      );

      expect(settings.activeEnrichmentProfile, isNull);
    });

    test('activeEnrichmentProfileId survives a JSON round-trip and is absent '
        'from legacy files', () {
      const AppSettings settings = AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'e1',
            name: 'GPT',
            endpoint: 'https://api.openai.com/v1/chat/completions',
            kind: ProfileKind.enrichment,
          ),
        ],
        activeEnrichmentProfileId: 'e1',
      );

      expect(
        AppSettings.fromJson(settings.toJson()).activeEnrichmentProfile?.id,
        'e1',
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{}).activeEnrichmentProfileId,
        isNull,
      );
    });

    test('the two active ids are independent', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      final ProviderProfile whisper = await controller.addProfile(
        name: 'Whisper',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      );
      final ProviderProfile gpt = await controller.addProfile(
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
        model: 'gpt-4o-mini',
      );

      // Adding the enrichment profile must not repoint transcription.
      expect(controller.settings.activeProfileId, whisper.id);
      expect(controller.settings.activeEnrichmentProfileId, gpt.id);
      expect(
        controller.transcriptionService,
        isA<HttpWhisperTranscriptionService>(),
      );
      expect(controller.enrichmentService, isA<HttpChatEnrichmentService>());
      expect(
        controller.profilesOfKind(ProfileKind.enrichment).single.id,
        gpt.id,
      );
    });

    test(
      'deleting the active enrichment profile falls back, never dangles',
      () async {
        final SettingsController controller = SettingsController(
          repository: _FakeSettingsRepository(),
        );

        final ProviderProfile first = await controller.addProfile(
          name: 'GPT',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          kind: ProfileKind.enrichment,
        );
        final ProviderProfile second = await controller.addProfile(
          name: 'Groq',
          endpoint: 'https://api.groq.com/openai/v1/chat/completions',
          kind: ProfileKind.enrichment,
        );

        await controller.deleteProfile(second.id);
        expect(controller.settings.activeEnrichmentProfileId, first.id);

        await controller.deleteProfile(first.id);
        expect(controller.settings.activeEnrichmentProfileId, isNull);
        expect(controller.enrichmentService, isA<DisabledEnrichmentService>());
      },
    );

    test('deleting a transcription profile never falls back to an enrichment '
        'one', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      final ProviderProfile whisper = await controller.addProfile(
        name: 'Whisper',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      );
      final ProviderProfile gpt = await controller.addProfile(
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
      );

      await controller.deleteProfile(whisper.id);

      // The chat endpoint cannot transcribe; no active profile beats a wrong one.
      expect(controller.settings.activeProfileId, isNull);
      expect(controller.settings.activeEnrichmentProfileId, gpt.id);
      expect(
        controller.transcriptionService,
        isA<DisabledTranscriptionService>(),
      );
    });

    test(
      'enrichmentService is cached until the connection details change',
      () async {
        final SettingsController controller = SettingsController(
          repository: _FakeSettingsRepository(),
        );

        final ProviderProfile gpt = await controller.addProfile(
          name: 'GPT',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          kind: ProfileKind.enrichment,
          model: 'gpt-4o-mini',
        );

        final EnrichmentService first = controller.enrichmentService;
        expect(identical(controller.enrichmentService, first), isTrue);

        await controller.updateProfile(gpt.copyWith(model: 'gpt-4.1-mini'));
        expect(identical(controller.enrichmentService, first), isFalse);
      },
    );

    test('setActiveEnrichmentProfile(null) disables enrichment', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      await controller.addProfile(
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
      );
      await controller.setActiveEnrichmentProfile(null);

      expect(controller.settings.activeEnrichmentProfileId, isNull);
      expect(controller.enrichmentService, isA<DisabledEnrichmentService>());
    });
  });

  group('OCR service off the enrichment profile', () {
    test('active enrichment profile powers OCR; none means disabled', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      expect(controller.ocrService, isA<DisabledOcrService>());

      await controller.addProfile(
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
        model: 'gpt-4o-mini',
      );

      expect(controller.ocrService, isA<HttpVisionOcrService>());
    });

    test('cached until the shared connection details change', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      final ProviderProfile gpt = await controller.addProfile(
        name: 'GPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        kind: ProfileKind.enrichment,
        model: 'gpt-4o-mini',
      );

      final OcrService first = controller.ocrService;
      expect(identical(controller.ocrService, first), isTrue);

      await controller.updateProfile(gpt.copyWith(model: 'gpt-4.1-mini'));
      expect(identical(controller.ocrService, first), isFalse);
    });

    test('a transcription profile never powers OCR', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );

      await controller.addProfile(
        name: 'Whisper',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        kind: ProfileKind.transcription,
      );

      expect(controller.ocrService, isA<DisabledOcrService>());
    });
  });

  group('ProviderPreset', () {
    test('the enrichment section has presets with model suggestions', () {
      final List<ProviderPreset> enrichment = ProviderPreset.all
          .where((ProviderPreset p) => p.kind == ProfileKind.enrichment)
          .toList();
      expect(enrichment, isNotEmpty);
      expect(
        enrichment.where((ProviderPreset p) => p.models.isNotEmpty),
        isNotEmpty,
      );
    });

    test('every non-custom preset endpoint parses with a scheme and host', () {
      for (final ProviderPreset preset in ProviderPreset.all) {
        if (preset.endpoint.isEmpty) continue;
        final Uri? uri = Uri.tryParse(preset.endpoint);
        expect(uri, isNotNull, reason: preset.name);
        expect(
          uri!.hasScheme && uri.host.isNotEmpty,
          isTrue,
          reason: preset.name,
        );
      }
    });
  });
}

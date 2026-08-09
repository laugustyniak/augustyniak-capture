import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/app_theme_mode.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/enrichment/data/http_chat_enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_defaults.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/processing/data/http_vision_ocr_service.dart';
import 'package:augustyniak_capture/features/processing/data/ocr_service.dart';
import 'package:augustyniak_capture/features/recordings/domain/note_vault.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

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
      // A `settings.json` written before the theme existed follows the OS,
      // which is what the app did implicitly anyway.
      expect(restored.themeMode, AppThemeMode.system);
    });

    test('theme mode survives a round-trip and degrades on a bad value', () {
      const AppSettings original = AppSettings(themeMode: AppThemeMode.light);

      expect(
        AppSettings.fromJson(original.toJson()).themeMode,
        AppThemeMode.light,
      );
      // Unlike `shortcuts`, this key is always written: `system` is a
      // delegation rather than a default a later build could improve on.
      expect(
        const AppSettings().toJson()['themeMode'],
        AppThemeMode.system.name,
      );
      // A newer build's fourth mode, or a hand-edited file, must not take the
      // profiles down with it.
      expect(
        AppSettings.fromJson(<String, dynamic>{'themeMode': 'sepia'}).themeMode,
        AppThemeMode.system,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{'themeMode': 7}).themeMode,
        AppThemeMode.system,
      );
    });

    test('vault settings survive a round-trip', () {
      const AppSettings original = AppSettings(
        vaultPath: '/Users/me/Vault',
        vaultFolder: 'Inbox/Capture',
        vaultCopySources: false,
      );

      final AppSettings restored = AppSettings.fromJson(original.toJson());

      expect(restored.vaultPath, '/Users/me/Vault');
      expect(restored.vaultFolder, 'Inbox/Capture');
      expect(restored.vaultCopySources, isFalse);
      expect(restored.mirrorsToVault, isTrue);
    });

    test('an install that mirrors nothing writes no vault keys', () {
      const AppSettings fresh = AppSettings();

      expect(fresh.mirrorsToVault, isFalse);
      expect(fresh.toJson().containsKey('vaultPath'), isFalse);
      expect(fresh.toJson().containsKey('vaultFolder'), isFalse);
      // A settings.json written before the vault existed loads with the mirror
      // off and the shipped subfolder, exactly like a fresh install.
      final AppSettings legacy = AppSettings.fromJson(<String, dynamic>{
        'profiles': <dynamic>[],
      });
      expect(legacy.vaultPath, isNull);
      expect(legacy.vaultFolder, VaultDefaults.folder);
      expect(legacy.vaultCopySources, isTrue);
    });

    test('a hand-edited vault path of the wrong type is ignored', () {
      final AppSettings restored = AppSettings.fromJson(<String, dynamic>{
        'vaultPath': 42,
        'vaultFolder': <String>['nope'],
        'vaultCopySources': 'yes',
      });

      expect(restored.vaultPath, isNull);
      expect(restored.vaultFolder, VaultDefaults.folder);
      expect(restored.vaultCopySources, isTrue);
    });

    test('clearing the vault path is a decision copyWith preserves', () {
      const AppSettings mirroring = AppSettings(vaultPath: '/Users/me/Vault');

      expect(mirroring.copyWith(clearVaultPath: true).vaultPath, isNull);
      // An unrelated save carries it through, like every other field here.
      expect(
        mirroring
            .copyWith(audio: const AudioConfig(sampleRate: 44100))
            .vaultPath,
        '/Users/me/Vault',
      );
    });

    test('copyWith carries the theme through an unrelated save', () {
      const AppSettings dark = AppSettings(themeMode: AppThemeMode.dark);

      expect(
        dark.copyWith(audio: const AudioConfig(sampleRate: 44100)).themeMode,
        AppThemeMode.dark,
      );
    });

    test('an untouched install resolves to the shipped default', () {
      const AppSettings fresh = AppSettings();

      expect(fresh.hasCustomEnrichmentInstructions, isFalse);
      expect(fresh.enrichmentInstructions, EnrichmentProfileDefaults.text);
      // Absent from JSON too, so a later build shipping a better default still
      // reaches everyone who never wrote their own — the `shortcuts` rule.
      expect(fresh.toJson().containsKey('enrichmentInstructions'), isFalse);
      expect(
        AppSettings.fromJson(<String, dynamic>{}).enrichmentInstructions,
        EnrichmentProfileDefaults.text,
      );
    });

    test('a stored value round-trips and wins over the default', () {
      const AppSettings original = AppSettings(
        enrichmentInstructions: 'I collect specs and meeting notes.',
      );

      expect(original.hasCustomEnrichmentInstructions, isTrue);
      final AppSettings restored = AppSettings.fromJson(original.toJson());
      expect(
        restored.enrichmentInstructions,
        'I collect specs and meeting notes.',
      );
      expect(restored.hasCustomEnrichmentInstructions, isTrue);
    });

    test('a deliberately emptied profile is not the default coming back', () {
      // The distinction the three-state rule exists for: "send no profile" has
      // to survive a restart rather than springing the default back.
      const AppSettings emptied = AppSettings(enrichmentInstructions: '');

      expect(emptied.hasCustomEnrichmentInstructions, isTrue);
      expect(emptied.enrichmentInstructions, isEmpty);
      expect(
        AppSettings.fromJson(emptied.toJson()).enrichmentInstructions,
        isEmpty,
      );
    });

    test('a wrong type in the file degrades to the default, not a throw', () {
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'enrichmentInstructions': 42,
        }).enrichmentInstructions,
        EnrichmentProfileDefaults.text,
      );
    });

    test('reset goes back to the default, and copyWith does not promote', () {
      const AppSettings custom = AppSettings(enrichmentInstructions: 'x');

      expect(
        custom
            .copyWith(resetEnrichmentInstructions: true)
            .hasCustomEnrichmentInstructions,
        isFalse,
      );
      expect(custom.copyWith().enrichmentInstructions, 'x');
      // An unrelated save must not turn an untouched install into a custom one.
      expect(
        const AppSettings()
            .copyWith(audio: const AudioConfig(sampleRate: 22050))
            .hasCustomEnrichmentInstructions,
        isFalse,
      );
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

    test('the profile starts at the default and reset returns to it', () async {
      final SettingsController controller = SettingsController(
        repository: _FakeSettingsRepository(),
      );
      await controller.initialize();

      expect(controller.hasCustomEnrichmentInstructions, isFalse);
      expect(controller.enrichmentInstructions, EnrichmentProfileDefaults.text);

      await controller.setEnrichmentInstructions('  I collect specs.  ');
      expect(controller.enrichmentInstructions, 'I collect specs.');
      expect(controller.hasCustomEnrichmentInstructions, isTrue);

      // Blank is a decision, not a clear: it must not resurrect the default.
      await controller.setEnrichmentInstructions('   ');
      expect(controller.enrichmentInstructions, isEmpty);
      expect(controller.hasCustomEnrichmentInstructions, isTrue);

      await controller.resetEnrichmentInstructions();
      expect(controller.enrichmentInstructions, EnrichmentProfileDefaults.text);
      expect(controller.hasCustomEnrichmentInstructions, isFalse);
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

    // OCR has no local engine behind it on any platform: an image capture works
    // only through a hosted vision endpoint.
    // These three are what the README offers as the ready-made way to get one,
    // so a preset that quietly stopped building a real service — a typo in the
    // endpoint is enough, since `toOcrService` degrades rather than throwing —
    // would turn every image capture into a `failed` row with nothing on screen
    // pointing at the cause.
    test(
      'the vision-capable defaults build real enrichment and OCR services',
      () {
        for (final String name in <String>[
          'OpenAI',
          'Anthropic',
          'Google Gemini',
        ]) {
          final ProviderPreset preset = ProviderPreset.all.singleWhere(
            (ProviderPreset p) =>
                p.name == name && p.kind == ProfileKind.enrichment,
            orElse: () => throw StateError('missing enrichment preset: $name'),
          );
          final ProviderProfile profile = ProviderProfile(
            id: 'p',
            name: preset.name,
            endpoint: preset.endpoint,
            kind: preset.kind,
            model: preset.model,
          );

          expect(
            profile.toEnrichmentService(),
            isA<HttpChatEnrichmentService>(),
            reason: name,
          );
          expect(
            profile.toOcrService(),
            isA<HttpVisionOcrService>(),
            reason: name,
          );
          expect(preset.model, isNotNull, reason: name);
          expect(preset.models, contains(preset.model), reason: name);
        }
      },
    );

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

  group('SettingsController.sealedTokensUnreadable', () {
    Future<SettingsController> controllerWith(AppSettings settings) async {
      final _FakeSettingsRepository repo = _FakeSettingsRepository()
        ..stored = settings;
      final SettingsController controller = SettingsController(
        repository: repo,
      );
      await controller.initialize();
      return controller;
    }

    AppSettings withProfileToken(String? token) => AppSettings(
      profiles: <ProviderProfile>[
        ProviderProfile(
          id: 'p1',
          name: 'OpenAI',
          endpoint: 'https://api.openai.com/v1/audio/transcriptions',
          bearerToken: token,
        ),
      ],
      activeProfileId: 'p1',
    );

    test(
      'is true when encryption is off and a stored token stayed sealed',
      () async {
        // The state that cost a day: requests go out with no Authorization
        // header at all, and the provider answers 401 "you didn't provide an API
        // key". Nothing on screen connected that to the key store.
        final SettingsController controller = await controllerWith(
          withProfileToken('enc:v1:unreadable-blob'),
        );

        expect(controller.sealedTokensUnreadable, isTrue);
      },
    );

    test('is false for the ordinary plaintext fallback', () async {
      // No keyring, but nothing was ever encrypted either — tokens work, and
      // the existing amber "stored as plaintext" note is the right message.
      final SettingsController controller = await controllerWith(
        withProfileToken('sk-secret'),
      );

      expect(controller.sealedTokensUnreadable, isFalse);
    });

    test('is false when there are no tokens at all', () async {
      final SettingsController controller = await controllerWith(
        withProfileToken(null),
      );

      expect(controller.sealedTokensUnreadable, isFalse);
    });

    test('a sealed sync credential counts too', () async {
      // The queue's 401 is the loud symptom, but an unopenable Turso token
      // fails just as silently and from the same cause.
      final SettingsController controller = await controllerWith(
        const AppSettings(tursoAuthToken: 'enc:v1:unreadable-blob'),
      );

      expect(controller.sealedTokensUnreadable, isTrue);
    });
  });
}

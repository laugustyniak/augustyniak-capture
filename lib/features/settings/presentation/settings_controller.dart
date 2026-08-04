import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../enrichment/domain/enrichment_service.dart';
import '../../processing/data/ocr_service.dart';
import '../../shortcuts/domain/hotkey_binding.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../transcription/data/transcription_service.dart';
import '../data/settings_repository.dart';
import '../domain/app_settings.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';

/// Owns runtime settings: transcription provider profiles and capture
/// parameters. Every mutation persists the whole `settings.json`, mirroring how
/// `RecordingsController` rewrites the whole recordings index.
class SettingsController extends ChangeNotifier {
  SettingsController({SettingsRepository? repository})
    : _repository = repository ?? SettingsRepository();

  static const String openAiEndpoint =
      'https://api.openai.com/v1/audio/transcriptions';

  final SettingsRepository _repository;
  final Uuid _uuid = const Uuid();

  AppSettings _settings = AppSettings.empty;
  String? _error;

  // Cached so that unrelated changes (audio params, profile reordering) don't
  // spawn a fresh HttpWhisperTranscriptionService — and with it a fresh
  // http.Client — on every notification.
  TranscriptionService? _service;
  String? _serviceSignature;
  EnrichmentService? _enrichment;
  String? _enrichmentSignature;
  OcrService? _ocr;
  String? _ocrSignature;

  AppSettings get settings => _settings;
  List<ProviderProfile> get profiles => _settings.profiles;
  ProviderProfile? get activeProfile => _settings.activeProfile;
  ProviderProfile? get activeEnrichmentProfile =>
      _settings.activeEnrichmentProfile;

  /// The profiles of one kind, for the two Models-tab sections.
  List<ProviderProfile> profilesOfKind(ProfileKind kind) => _settings.profiles
      .where((ProviderProfile item) => item.kind == kind)
      .toList();
  AudioConfig get audio => _settings.audio;
  String? get enrichmentInstructions => _settings.enrichmentInstructions;
  String? get error => _error;

  /// The service the recordings controller should use right now. No active
  /// profile means transcription reports "not configured" — same as a fresh
  /// install with no `--dart-define`.
  ///
  /// The same instance is returned until the active profile's connection
  /// details actually change.
  TranscriptionService get transcriptionService {
    final ProviderProfile? active = _settings.activeProfile;
    final String signature = active == null
        ? 'disabled'
        : <String?>[
            active.id,
            active.endpoint,
            active.model,
            active.language,
            active.bearerToken,
          ].join('|');

    if (_service == null || _serviceSignature != signature) {
      _service = active?.toService() ?? const DisabledTranscriptionService();
      _serviceSignature = signature;
    }
    return _service!;
  }

  /// The enrichment service the recordings controller should use right now.
  ///
  /// Same caching rule as [transcriptionService]: the same instance — and so the
  /// same `http.Client` — until the active profile's connection details actually
  /// change. No `language` in the signature, because the enrichment request does
  /// not send one.
  EnrichmentService get enrichmentService {
    final ProviderProfile? active = _settings.activeEnrichmentProfile;
    final String signature = active == null
        ? 'disabled'
        : <String?>[
            active.id,
            active.endpoint,
            active.model,
            active.bearerToken,
          ].join('|');

    if (_enrichment == null || _enrichmentSignature != signature) {
      _enrichment =
          active?.toEnrichmentService() ?? const DisabledEnrichmentService();
      _enrichmentSignature = signature;
    }
    return _enrichment!;
  }

  /// The image-OCR service, derived from the **enrichment** profile — OCR has
  /// no profile kind of its own (see [ProviderProfile.toOcrService]). Returns
  /// the disabled service when no enrichment profile is active; the shell
  /// decides what to fall back to (tesseract on desktop, nothing on mobile).
  ///
  /// Same caching rule and the same signature fields as [enrichmentService]:
  /// the two services share one profile, so they invalidate together.
  OcrService get ocrService {
    final ProviderProfile? active = _settings.activeEnrichmentProfile;
    final String signature = active == null
        ? 'disabled'
        : <String?>[
            active.id,
            active.endpoint,
            active.model,
            active.bearerToken,
          ].join('|');

    if (_ocr == null || _ocrSignature != signature) {
      _ocr = active?.toOcrService() ?? const DisabledOcrService();
      _ocrSignature = signature;
    }
    return _ocr!;
  }

  Future<void> initialize() async {
    try {
      final AppSettings? stored = await _repository.load();
      if (stored != null) {
        _settings = stored;
      } else {
        // First run: build-time defines seed the first profile, then the saved
        // file wins forever after.
        _settings = _seedFromEnvironment();
        if (_settings.profiles.isNotEmpty) {
          await _repository.save(_settings);
        }
      }
    } catch (exception) {
      _error = exception.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<ProviderProfile> addProfile({
    required String name,
    required String endpoint,
    ProfileKind kind = ProfileKind.transcription,
    String? model,
    String? language,
    String? bearerToken,
  }) async {
    final ProviderProfile profile = ProviderProfile(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Profile' : name.trim(),
      endpoint: endpoint.trim(),
      kind: kind,
      model: model,
      language: language,
      bearerToken: bearerToken,
    );

    await _persist(
      _settings.copyWith(
        profiles: <ProviderProfile>[..._settings.profiles, profile],
        // A newly added profile becomes the active one *of its own kind*:
        // adding an enrichment profile must not silently repoint transcription.
        activeProfileId: kind == ProfileKind.transcription
            ? profile.id
            : _settings.activeProfileId,
        activeEnrichmentProfileId: kind == ProfileKind.enrichment
            ? profile.id
            : _settings.activeEnrichmentProfileId,
      ),
    );
    return profile;
  }

  Future<void> updateProfile(ProviderProfile updated) async {
    await _persist(
      _settings.copyWith(
        profiles: _settings.profiles
            .map(
              (ProviderProfile item) => item.id == updated.id ? updated : item,
            )
            .toList(),
      ),
    );
  }

  Future<void> deleteProfile(String id) async {
    final List<ProviderProfile> remaining = _settings.profiles
        .where((ProviderProfile item) => item.id != id)
        .toList();

    // Resolve against what actually survives rather than only handling the
    // "deleted the active one" case: an id that was already dangling (a
    // hand-edited settings.json) would otherwise be carried forward untouched.
    // Each kind falls back to the first profile left *of that kind* — never to
    // a profile that speaks the wrong protocol.
    String? resolve(String? current, ProfileKind kind) {
      if (remaining.any((ProviderProfile item) => item.id == current)) {
        return current;
      }
      for (final ProviderProfile item in remaining) {
        if (item.kind == kind) return item.id;
      }
      return null;
    }

    final String? nextActive = resolve(
      _settings.activeProfileId,
      ProfileKind.transcription,
    );
    final String? nextEnrichment = resolve(
      _settings.activeEnrichmentProfileId,
      ProfileKind.enrichment,
    );

    await _persist(
      _settings.copyWith(
        profiles: remaining,
        activeProfileId: nextActive,
        clearActiveProfileId: nextActive == null,
        activeEnrichmentProfileId: nextEnrichment,
        clearActiveEnrichmentProfileId: nextEnrichment == null,
      ),
    );
  }

  Future<void> setActiveProfile(String? id) async {
    await _persist(
      _settings.copyWith(activeProfileId: id, clearActiveProfileId: id == null),
    );
  }

  Future<void> setActiveEnrichmentProfile(String? id) async {
    await _persist(
      _settings.copyWith(
        activeEnrichmentProfileId: id,
        clearActiveEnrichmentProfileId: id == null,
      ),
    );
  }

  /// Replace the user's enrichment profile text. Blank clears it.
  ///
  /// Note there is no service cache to invalidate here, unlike every other
  /// setting on this controller: the instructions travel as a per-call argument
  /// to `EnrichmentService.enrich`, not as constructor state, so a change takes
  /// effect on the very next capture without rebuilding the `http.Client`.
  Future<void> setEnrichmentInstructions(String? value) async {
    final String trimmed = value?.trim() ?? '';
    if (trimmed == (_settings.enrichmentInstructions ?? '')) return;
    await _persist(
      _settings.copyWith(
        enrichmentInstructions: trimmed.isEmpty ? null : trimmed,
        clearEnrichmentInstructions: trimmed.isEmpty,
      ),
    );
  }

  Future<void> updateAudio(AudioConfig audio) async {
    await _persist(_settings.copyWith(audio: audio));
  }

  Future<void> resetAudio() => updateAudio(AudioConfig.defaults);

  /// Bind [action] to [binding].
  ///
  /// A combination can only drive one action, so taking it from another leaves
  /// that one unbound rather than registering the same hotkey twice — the OS
  /// would hand the press to whichever registration happened to win, which is
  /// not a coin flip worth exposing to the user.
  Future<void> setShortcut(ShortcutAction action, HotkeyBinding binding) async {
    if (!binding.isValid) return;
    final Map<ShortcutAction, HotkeyBinding> next =
        Map<ShortcutAction, HotkeyBinding>.from(_settings.shortcuts)
          ..removeWhere(
            (ShortcutAction other, HotkeyBinding existing) =>
                other != action && existing == binding,
          )
          ..[action] = binding;
    await _persist(_settings.copyWith(shortcuts: next));
  }

  /// Unbind [action]. Persisting the map with the entry removed is what stops
  /// the default from coming back on the next launch.
  Future<void> clearShortcut(ShortcutAction action) async {
    final Map<ShortcutAction, HotkeyBinding> next =
        Map<ShortcutAction, HotkeyBinding>.from(_settings.shortcuts)
          ..remove(action);
    await _persist(_settings.copyWith(shortcuts: next));
  }

  Future<void> resetShortcuts() =>
      _persist(_settings.copyWith(resetShortcuts: true));

  Future<void> _persist(AppSettings next) async {
    _settings = next;
    _error = null;
    notifyListeners();
    try {
      await _repository.save(next);
    } catch (exception) {
      _error = exception.toString();
      notifyListeners();
    }
  }

  /// Legacy `--dart-define` path, kept as the first-run default:
  ///   flutter run --dart-define=TRANSCRIPTION_TOKEN=sk-... \
  ///               --dart-define=TRANSCRIPTION_MODEL=whisper-1
  static AppSettings _seedFromEnvironment() {
    const String endpointDefine = String.fromEnvironment(
      'TRANSCRIPTION_ENDPOINT',
    );
    const String token = String.fromEnvironment('TRANSCRIPTION_TOKEN');
    const String model = String.fromEnvironment(
      'TRANSCRIPTION_MODEL',
      defaultValue: 'whisper-1',
    );
    const String language = String.fromEnvironment('TRANSCRIPTION_LANGUAGE');

    final String endpoint = endpointDefine.isNotEmpty
        ? endpointDefine
        : (token.isNotEmpty ? openAiEndpoint : '');
    if (endpoint.isEmpty) {
      return AppSettings.empty;
    }

    const ProviderProfile seeded = ProviderProfile(
      id: 'build-define',
      name: 'From build config',
      endpoint: '',
    );
    final ProviderProfile profile = seeded.copyWith(
      endpoint: endpoint,
      model: model.isEmpty ? null : model,
      language: language.isEmpty ? null : language,
      bearerToken: token.isEmpty ? null : token,
    );

    return AppSettings(
      profiles: <ProviderProfile>[profile],
      activeProfileId: profile.id,
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

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

  AppSettings get settings => _settings;
  List<ProviderProfile> get profiles => _settings.profiles;
  ProviderProfile? get activeProfile => _settings.activeProfile;
  AudioConfig get audio => _settings.audio;
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
    String? model,
    String? language,
    String? bearerToken,
  }) async {
    final ProviderProfile profile = ProviderProfile(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Profile' : name.trim(),
      endpoint: endpoint.trim(),
      model: model,
      language: language,
      bearerToken: bearerToken,
    );

    await _persist(
      _settings.copyWith(
        profiles: <ProviderProfile>[..._settings.profiles, profile],
        // A newly added profile always becomes the active one.
        activeProfileId: profile.id,
      ),
    );
    return profile;
  }

  Future<void> updateProfile(ProviderProfile updated) async {
    await _persist(
      _settings.copyWith(
        profiles: _settings.profiles
            .map((ProviderProfile item) =>
                item.id == updated.id ? updated : item)
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
    // hand-edited settings.json) would otherwise be carried forward untouched,
    // which the comment below claimed could not happen.
    final bool activeSurvives = remaining
        .any((ProviderProfile item) => item.id == _settings.activeProfileId);
    final String? nextActive = activeSurvives
        ? _settings.activeProfileId
        : (remaining.isEmpty ? null : remaining.first.id);

    await _persist(
      _settings.copyWith(
        profiles: remaining,
        // Falls back to the first profile left, or to nothing at all — never to
        // a dangling id.
        activeProfileId: nextActive,
        clearActiveProfileId: nextActive == null,
      ),
    );
  }

  Future<void> setActiveProfile(String? id) async {
    await _persist(
      _settings.copyWith(
        activeProfileId: id,
        clearActiveProfileId: id == null,
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
          ..removeWhere((ShortcutAction other, HotkeyBinding existing) =>
              other != action && existing == binding)
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
    const String endpointDefine =
        String.fromEnvironment('TRANSCRIPTION_ENDPOINT');
    const String token = String.fromEnvironment('TRANSCRIPTION_TOKEN');
    const String model =
        String.fromEnvironment('TRANSCRIPTION_MODEL', defaultValue: 'whisper-1');
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

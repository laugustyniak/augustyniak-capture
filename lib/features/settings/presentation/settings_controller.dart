import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../costs/domain/model_price.dart';
import '../../costs/domain/price_book.dart';
import '../../costs/domain/usage_sink.dart';
import '../../command/data/http_command_client.dart';
import '../../command/domain/command_client.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../../processing/data/ocr_service.dart';
import '../../shortcuts/domain/hotkey_binding.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../timer/domain/alarm_sound.dart';
import '../../timer/domain/timer_defaults.dart';
import '../../transcription/data/local_transcription_service.dart';
import '../../transcription/data/transcription_service.dart';
import '../../transcription/domain/local_transcription_engine.dart';
import '../data/settings_repository.dart';
import '../domain/app_settings.dart';
import '../domain/app_theme_mode.dart';
import '../domain/audio_config.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';

/// Owns runtime settings: transcription provider profiles and capture
/// parameters. Every mutation persists the whole `settings.json`, mirroring how
/// `RecordingsController` rewrites the whole recordings index.
class SettingsController extends ChangeNotifier {
  SettingsController({
    SettingsRepository? repository,
    UsageSink usageSink = const NoopUsageSink(),
    LocalTranscriptionEngine localEngine = const UnavailableLocalEngine(),
    Future<String?> Function(String modelId)? localModelPath,
  }) : _repository = repository ?? SettingsRepository(),
       _usageSink = usageSink,
       _localEngine = localEngine,
       _localModelPath = localModelPath ?? _noLocalModel;

  /// Runs a model on this machine. Unavailable until a build ships the native
  /// engine, which is what makes a local profile fail readably rather than
  /// silently doing nothing.
  final LocalTranscriptionEngine _localEngine;

  /// Where an installed model lives, or null when it is not installed. Answers
  /// null everywhere until the model store lands — a local profile is then a
  /// profile pointing at nothing, and says so.
  final Future<String?> Function(String modelId) _localModelPath;

  static Future<String?> _noLocalModel(String modelId) async => null;

  /// Whether this build can run a model at all, and why not when it cannot.
  /// Read by the Models tab, which says it once rather than per capture.
  bool get localEngineAvailable => _localEngine.isAvailable;
  String? get localEngineIssue => _localEngine.unavailableReason;

  static const String openAiEndpoint =
      'https://api.openai.com/v1/audio/transcriptions';

  final SettingsRepository _repository;

  /// Threaded into every service this controller builds, so a transcription,
  /// enrichment or OCR call scoped by the recordings controller's
  /// `beginJob`/`endJob` records against the capture that caused it.
  final UsageSink _usageSink;
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

  /// Which palette the app paints in. Read by the shell, which lifts it above
  /// the `MaterialApp`.
  AppThemeMode get themeMode => _settings.themeMode;

  /// Never null: an untouched install resolves to the shipped default.
  String get enrichmentInstructions => _settings.enrichmentInstructions;

  /// False while the shipped default is in force, so the editor can disable
  /// "restore default" and label which of the two is on screen.
  bool get hasCustomEnrichmentInstructions =>
      _settings.hasCustomEnrichmentInstructions;
  String? get error => _error;

  /// Whether tokens written to disk are actually encrypted. False on the
  /// plaintext fallback (no master key) so the Models/Config tabs can say so.
  bool get tokenEncryptionActive => _repository.encryptsTokens;

  /// What the key store said when it refused, for the Models tab. Null when
  /// encryption is on, and null before [initialize] has made the cipher try —
  /// a reason that has not been established yet must not read as "no problem"
  /// combined with [tokenEncryptionActive], which is false at that point too.
  String? get tokenEncryptionIssue => _repository.tokenEncryptionIssue;

  /// True when secrets on disk are encrypted and this launch cannot open them:
  /// a stored value still carries the `enc:v1:` marker after [initialize] has
  /// run the cipher over it.
  ///
  /// **This is a failure, not the plaintext fallback, and the two must not
  /// share a message.** With no master key an install simply never encrypts and
  /// every token keeps working; here they were encrypted, the key is out of
  /// reach, and `ProviderProfile.usableBearerToken` drops each blob rather than
  /// putting it in an `Authorization` header. The observable result is a 401
  /// reading "you didn't provide an API key" on every capture, with the amber
  /// "stored as plaintext" note — which is the opposite of what happened —
  /// as the only thing on screen.
  bool get sealedTokensUnreadable {
    if (tokenEncryptionActive) return false;
    bool sealed(String? value) => value != null && TokenCipher.isSealed(value);
    return _settings.profiles.any(
          (ProviderProfile profile) => sealed(profile.bearerToken),
        ) ||
        sealed(_settings.tursoAuthToken) ||
        sealed(_settings.r2SecretAccessKey) ||
        sealed(_settings.commandToken);
  }

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
            // The kind is in the signature because it decides *which* service
            // is built, not merely how one is configured — without it, editing
            // a profile from remote to local would keep the cached HTTP client.
            active.kind.name,
            active.id,
            active.endpoint,
            active.model,
            active.language,
            active.bearerToken,
          ].join('|');

    if (_service == null || _serviceSignature != signature) {
      _service = _buildTranscriptionService(active);
      _serviceSignature = signature;
    }
    return _service!;
  }

  /// A local profile is built here rather than in `ProviderProfile.toService`,
  /// because it needs two things the profile does not own: the engine and the
  /// model store. The profile only names which model it wants.
  TranscriptionService _buildTranscriptionService(ProviderProfile? active) {
    if (active == null) return const DisabledTranscriptionService();
    if (active.kind == ProfileKind.localWhisper) {
      return LocalTranscriptionService(
        engine: _localEngine,
        // The `model` field names the catalog entry here, exactly as it names
        // the remote model elsewhere — one field, one meaning per kind.
        modelId: active.model?.trim() ?? '',
        modelPath: _localModelPath,
        language: active.language?.trim().isEmpty ?? true
            ? null
            : active.language!.trim(),
      );
    }
    return active.toService(usageSink: _usageSink);
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
          active?.toEnrichmentService(usageSink: _usageSink) ??
          const DisabledEnrichmentService();
      _enrichmentSignature = signature;
    }
    return _enrichment!;
  }

  /// The image-OCR service, derived from the **enrichment** profile — OCR has
  /// no profile kind of its own (see [ProviderProfile.toOcrService]). Returns
  /// the disabled service when no enrichment profile is active, and that is the
  /// end of it: there is no local engine behind this on any platform, so an
  /// image captured without a vision profile fails readably and stays retryable.
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
      _ocr = active?.toOcrService(usageSink: _usageSink) ??
          const DisabledOcrService();
      _ocrSignature = signature;
    }
    return _ocr!;
  }

  /// The Command control-plane client, or the disabled one while no address is
  /// configured.
  ///
  /// Same caching rule as the three services above, and for the same reason:
  /// this notifier fires on every settings change, and rebuilding an
  /// `http.Client` per notification would throw away the connection pool a
  /// picker is about to use twice. The signature is the address and the token,
  /// which are the only two things that change what this client can reach.
  ///
  /// **A blank or schemeless address degrades to disabled rather than throwing**
  /// — the same rule `ProviderProfile.toService` follows. Half-typed
  /// configuration is the normal state of a text field, and it must not be able
  /// to fail anything but the call that needs it.
  CommandClient get commandClient {
    final String raw = _settings.commandBaseUrl?.trim() ?? '';
    final String token = _settings.commandToken ?? '';
    final String signature = '$raw|$token';
    if (_command != null && _commandSignature == signature) return _command!;

    final Uri? url = Uri.tryParse(raw);
    _command = raw.isEmpty || url == null || !url.hasScheme || url.host.isEmpty
        ? const DisabledCommandClient()
        : HttpCommandClient(
            baseUrl: url,
            bearerToken: _settings.usableCommandToken,
          );
    _commandSignature = signature;
    return _command!;
  }

  CommandClient? _command;
  String? _commandSignature;

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

  /// The catalog id of the on-device model currently doing the transcribing,
  /// or null when a remote profile is active.
  String? get activeLocalModelId {
    final ProviderProfile? active = _settings.activeProfile;
    if (active == null || active.kind != ProfileKind.localWhisper) return null;
    final String id = active.model?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  /// Makes [modelId] the transcriber.
  ///
  /// **One profile per model, reused rather than accumulated.** Selecting a
  /// model twice must not leave two identical entries in the Models tab — the
  /// profile is an implementation detail of "which model is active", and a list
  /// that grows every time somebody switches back and forth is a list nobody
  /// can read. The profile's `name` is refreshed from the catalog on each call
  /// so a relabelled model does not keep an old name forever.
  Future<void> useLocalModel(String modelId, {required String label}) async {
    final ProviderProfile? existing = _settings.profiles
        .where(
          (ProviderProfile item) =>
              item.kind == ProfileKind.localWhisper &&
              (item.model?.trim() ?? '') == modelId,
        )
        .firstOrNull;

    if (existing != null) {
      if (existing.name != label) {
        await updateProfile(existing.copyWith(name: label));
      }
      await setActiveProfile(existing.id);
      return;
    }

    final ProviderProfile created = await addProfile(
      name: label,
      // No endpoint by definition — see `ProviderProfile.toService`, which
      // reads the kind before it looks at this.
      endpoint: '',
      kind: ProfileKind.localWhisper,
      model: modelId,
    );
    await setActiveProfile(created.id);
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

  /// Replace the user's enrichment profile text.
  ///
  /// A blank value is **stored as blank**, not cleared: it means "send no
  /// profile", which is a different answer from "I never configured this" and
  /// must survive a restart. [resetEnrichmentInstructions] is the way back to
  /// the shipped default.
  ///
  /// Note there is no service cache to invalidate here, unlike every other
  /// setting on this controller: the instructions travel as a per-call argument
  /// to `EnrichmentService.enrich`, not as constructor state, so a change takes
  /// effect on the very next capture without rebuilding the `http.Client`.
  Future<void> setEnrichmentInstructions(String? value) async {
    final String trimmed = value?.trim() ?? '';
    if (_settings.hasCustomEnrichmentInstructions &&
        trimmed == _settings.enrichmentInstructions.trim()) {
      return;
    }
    await _persist(_settings.copyWith(enrichmentInstructions: trimmed));
  }

  /// Drop the user's text and go back to [EnrichmentProfileDefaults.text].
  Future<void> resetEnrichmentInstructions() =>
      _persist(_settings.copyWith(resetEnrichmentInstructions: true));

  Future<void> setTursoConfig({
    String? url,
    String? token,
    bool? enabled,
  }) async {
    await _persist(
      _settings.copyWith(
        tursoDbUrl: url,
        tursoAuthToken: token,
        tursoSyncEnabled: enabled,
      ),
    );
  }

  /// The control plane's address and fleet token.
  ///
  /// One setter for both, like [setTursoConfig]: they are useless apart, and a
  /// pair written in two saves has a moment on disk where the token belongs to
  /// an address that is no longer there.
  Future<void> setCommandConfig({String? baseUrl, String? token}) async {
    await _persist(
      _settings.copyWith(
        commandBaseUrl: baseUrl,
        clearCommandBaseUrl: baseUrl != null && baseUrl.trim().isEmpty,
        commandToken: token,
        clearCommandToken: token != null && token.trim().isEmpty,
      ),
    );
  }

  Future<void> setR2Config({
    String? endpoint,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
    bool? enabled,
  }) async {
    await _persist(
      _settings.copyWith(
        r2Endpoint: endpoint,
        r2Bucket: bucket,
        r2AccessKeyId: accessKeyId,
        r2SecretAccessKey: secretAccessKey,
        r2MediaSyncEnabled: enabled,
      ),
    );
  }

  /// Where captures are mirrored as markdown, or null when nothing is.
  String? get vaultPath => _settings.vaultPath;
  String get vaultFolder => _settings.vaultFolder;
  bool get vaultCopySources => _settings.vaultCopySources;
  bool get mirrorsToVault => _settings.mirrorsToVault;

  /// Point the mirror at a directory, or clear it with a blank value.
  ///
  /// The path is stored as typed, not validated here: the field stays
  /// authoritative on every platform (the browse dialog is desktop-only), and a
  /// directory can be unmounted and remounted between now and the next capture.
  /// The vault itself names a missing directory when it tries to write, which is
  /// the only moment the answer is actually knowable.
  ///
  /// Like `setEnrichmentInstructions` there is no service cache to invalidate:
  /// the vault reads this through a callback on every mirror, so a change
  /// applies to the very next note.
  Future<void> setVaultPath(String? value) async {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      if (_settings.vaultPath == null) return;
      await _persist(_settings.copyWith(clearVaultPath: true));
      return;
    }
    if (trimmed == _settings.vaultPath) return;
    await _persist(_settings.copyWith(vaultPath: trimmed));
  }

  Future<void> setVaultFolder(String value) async {
    final String trimmed = value.trim();
    if (trimmed == _settings.vaultFolder) return;
    await _persist(_settings.copyWith(vaultFolder: trimmed));
  }

  Future<void> setVaultCopySources(bool value) async {
    if (value == _settings.vaultCopySources) return;
    await _persist(_settings.copyWith(vaultCopySources: value));
  }

  /// How long a focus session runs, and what plays when it ends.
  ///
  /// Owned here rather than by `FocusTimerController` for the same reason the
  /// audio config is owned here rather than by `RecordingsController`: it is
  /// configuration that has to survive a restart, and the controller that runs
  /// on it holds no persisted state at all. The shell pushes both down.
  Duration get timerDuration => _settings.timerDuration;
  AlarmSound get timerAlarm => _settings.timerAlarm;

  Future<void> setTimerDuration(Duration value) async {
    final int minutes = TimerDefaults.clamp(value).inMinutes;
    if (minutes == _settings.timerMinutes) return;
    await _persist(_settings.copyWith(timerMinutes: minutes));
  }

  Future<void> setTimerAlarm(AlarmSound value) async {
    if (value == _settings.timerAlarm) return;
    await _persist(_settings.copyWith(timerAlarm: value));
  }

  Future<void> updateAudio(AudioConfig audio) async {
    await _persist(_settings.copyWith(audio: audio));
  }

  Future<void> resetAudio() => updateAudio(AudioConfig.defaults);

  /// What the Config tab's PRICING section reads and edits.
  Map<String, ModelPrice> get priceOverrides => _settings.priceOverrides;
  StoragePrice get storagePrice => _settings.storagePrice;
  bool get hasCustomStoragePrice => _settings.hasCustomStoragePrice;

  /// Set, replace or clear one model's rate override.
  ///
  /// `price == null`, and a [ModelPrice] whose [ModelPrice.isEmpty] is true —
  /// what the editor produces when every field is cleared — both remove the
  /// key rather than storing a blank entry, so the shipped table in
  /// `PriceBookDefaults` takes back over for that model on the next capture.
  Future<void> setPriceOverride(String key, ModelPrice? price) async {
    final Map<String, ModelPrice> next = Map<String, ModelPrice>.from(
      _settings.priceOverrides,
    );
    if (price == null || price.isEmpty) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      next[key] = price;
    }
    await _persist(_settings.copyWith(priceOverrides: next));
  }

  /// Set the storage rate, or clear it back to [StoragePrice.defaults] with
  /// `null`. A non-null value is authoritative even when every field in it is
  /// zero — see [AppSettings.hasCustomStoragePrice].
  Future<void> setStoragePrice(StoragePrice? price) async {
    if (price == null) {
      if (!_settings.hasCustomStoragePrice) return;
      await _persist(_settings.copyWith(clearStoragePrice: true));
      return;
    }
    await _persist(_settings.copyWith(storagePrice: price));
  }

  /// Repaint the app in [mode].
  ///
  /// Persisted like anything else here, but it is the one setting the shell
  /// pushes *upwards* — the palette lives above `MaterialApp`, not below it —
  /// so the change reaches the screen through the shell's theme notifier rather
  /// than through a controller a widget listens to.
  Future<void> setThemeMode(AppThemeMode mode) async {
    if (mode == _settings.themeMode) return;
    await _persist(_settings.copyWith(themeMode: mode));
  }

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

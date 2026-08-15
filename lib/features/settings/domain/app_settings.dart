import '../../costs/domain/model_price.dart';
import '../../costs/domain/price_book.dart';
import '../../enrichment/domain/enrichment_defaults.dart';
import '../../recordings/domain/note_vault.dart';
import '../../shortcuts/domain/hotkey_binding.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../timer/domain/alarm_sound.dart';
import '../../timer/domain/timer_defaults.dart';
import 'app_theme_mode.dart';
import 'audio_config.dart';
import 'provider_profile.dart';
import 'token_cipher.dart';

class AppSettings {
  const AppSettings({
    this.profiles = const <ProviderProfile>[],
    this.activeProfileId,
    this.activeEnrichmentProfileId,
    String? enrichmentInstructions,
    this.audio = AudioConfig.defaults,
    this.themeMode = AppThemeMode.system,
    this.vaultPath,
    this.vaultFolder = VaultDefaults.folder,
    this.vaultCopySources = true,
    this.timerMinutes = TimerDefaults.defaultMinutes,
    this.timerAlarm = AlarmSound.fallback,
    this.tursoDbUrl,
    this.tursoAuthToken,
    this.tursoSyncEnabled = false,
    this.r2Endpoint,
    this.r2Bucket,
    this.r2AccessKeyId,
    this.r2SecretAccessKey,
    this.r2MediaSyncEnabled = false,
    this.commandBaseUrl,
    this.commandToken,
    this.priceOverrides = const <String, ModelPrice>{},
    StoragePrice? storagePrice,
    Map<ShortcutAction, HotkeyBinding>? shortcuts,
  }) : _enrichmentInstructions = enrichmentInstructions,
       _storagePrice = storagePrice,
       _shortcuts = shortcuts;

  static const AppSettings empty = AppSettings();

  final List<ProviderProfile> profiles;
  final String? activeProfileId;
  final String? activeEnrichmentProfileId;

  ProviderProfile? get activeProfile {
    final String? id = activeProfileId;
    if (id == null) return null;
    for (final ProviderProfile p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  ProviderProfile? get activeEnrichmentProfile {
    final String? id = activeEnrichmentProfileId;
    if (id == null) return null;
    for (final ProviderProfile p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  final String? _enrichmentInstructions;

  String get enrichmentInstructions =>
      _enrichmentInstructions ?? EnrichmentProfileDefaults.text;

  bool get hasCustomEnrichmentInstructions => _enrichmentInstructions != null;

  final AudioConfig audio;
  final AppThemeMode themeMode;
  final String? vaultPath;
  final String vaultFolder;
  final bool vaultCopySources;

  bool get mirrorsToVault => (vaultPath ?? '').trim().isNotEmpty;

  final int timerMinutes;
  final AlarmSound timerAlarm;

  Duration get timerDuration =>
      TimerDefaults.clamp(Duration(minutes: timerMinutes));

  final String? tursoDbUrl;
  final String? tursoAuthToken;
  final bool tursoSyncEnabled;

  final String? r2Endpoint;
  final String? r2Bucket;
  final String? r2AccessKeyId;
  final String? r2SecretAccessKey;
  final bool r2MediaSyncEnabled;

  /// The Command aggregator's base address, and the fleet token that reaches
  /// it. Both null until the user configures them, which is the normal state:
  /// with no control plane the app behaves exactly as it did before.
  ///
  /// The token is sealed at the `SettingsRepository` boundary like every other
  /// token here — AES-256-GCM under the OS keyring, `enc:v1:` on disk — so this
  /// field always holds plaintext in memory and never does on disk when a key
  /// store is available.
  final String? commandBaseUrl;
  final String? commandToken;

  /// The fleet token as a request header may carry it.
  ///
  /// A blob that no longer decrypts is preserved verbatim in [commandToken] —
  /// it recovers the moment the key store does — but it must never reach the
  /// wire, where it would be sent as a literal `enc:v1:…` string and answered
  /// with a 401 that says nothing about the real cause. Same rule, and the same
  /// reason, as `ProviderProfile.usableBearerToken`.
  String? get usableCommandToken {
    final String token = commandToken?.trim() ?? '';
    if (token.isEmpty || TokenCipher.isSealed(token)) return null;
    return token;
  }

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

  final Map<ShortcutAction, HotkeyBinding>? _shortcuts;

  Map<ShortcutAction, HotkeyBinding> get shortcuts {
    final Map<ShortcutAction, HotkeyBinding>? stored = _shortcuts;
    if (stored == null) return ShortcutDefaults.bindings;
    return Map<ShortcutAction, HotkeyBinding>.unmodifiable(stored);
  }

  bool get hasCustomShortcuts => _shortcuts != null;

  AppSettings copyWith({
    List<ProviderProfile>? profiles,
    String? activeProfileId,
    bool clearActiveProfileId = false,
    String? activeEnrichmentProfileId,
    bool clearActiveEnrichmentProfileId = false,
    String? enrichmentInstructions,
    bool resetEnrichmentInstructions = false,
    AudioConfig? audio,
    AppThemeMode? themeMode,
    String? vaultPath,
    bool clearVaultPath = false,
    String? vaultFolder,
    bool? vaultCopySources,
    int? timerMinutes,
    AlarmSound? timerAlarm,
    String? tursoDbUrl,
    String? tursoAuthToken,
    bool? tursoSyncEnabled,
    String? r2Endpoint,
    String? r2Bucket,
    String? r2AccessKeyId,
    String? r2SecretAccessKey,
    bool? r2MediaSyncEnabled,
    String? commandBaseUrl,
    bool clearCommandBaseUrl = false,
    String? commandToken,
    bool clearCommandToken = false,
    Map<String, ModelPrice>? priceOverrides,
    StoragePrice? storagePrice,
    bool clearStoragePrice = false,
    Map<ShortcutAction, HotkeyBinding>? shortcuts,
    bool resetShortcuts = false,
  }) {
    return AppSettings(
      profiles: profiles ?? this.profiles,
      activeProfileId: clearActiveProfileId
          ? null
          : (activeProfileId ?? this.activeProfileId),
      activeEnrichmentProfileId: clearActiveEnrichmentProfileId
          ? null
          : (activeEnrichmentProfileId ?? this.activeEnrichmentProfileId),
      enrichmentInstructions: resetEnrichmentInstructions
          ? null
          : (enrichmentInstructions ?? _enrichmentInstructions),
      audio: audio ?? this.audio,
      themeMode: themeMode ?? this.themeMode,
      vaultPath: clearVaultPath ? null : (vaultPath ?? this.vaultPath),
      vaultFolder: vaultFolder ?? this.vaultFolder,
      vaultCopySources: vaultCopySources ?? this.vaultCopySources,
      timerMinutes: timerMinutes ?? this.timerMinutes,
      timerAlarm: timerAlarm ?? this.timerAlarm,
      tursoDbUrl: tursoDbUrl ?? this.tursoDbUrl,
      tursoAuthToken: tursoAuthToken ?? this.tursoAuthToken,
      tursoSyncEnabled: tursoSyncEnabled ?? this.tursoSyncEnabled,
      r2Endpoint: r2Endpoint ?? this.r2Endpoint,
      r2Bucket: r2Bucket ?? this.r2Bucket,
      r2AccessKeyId: r2AccessKeyId ?? this.r2AccessKeyId,
      r2SecretAccessKey: r2SecretAccessKey ?? this.r2SecretAccessKey,
      r2MediaSyncEnabled: r2MediaSyncEnabled ?? this.r2MediaSyncEnabled,
      commandBaseUrl: clearCommandBaseUrl
          ? null
          : (commandBaseUrl ?? this.commandBaseUrl),
      commandToken: clearCommandToken
          ? null
          : (commandToken ?? this.commandToken),
      priceOverrides: priceOverrides ?? this.priceOverrides,
      storagePrice: clearStoragePrice
          ? null
          : (storagePrice ?? _storagePrice),
      shortcuts: resetShortcuts ? null : (shortcuts ?? _shortcuts),
    );
  }

  Map<String, dynamic> toJson() {
    final Map<ShortcutAction, HotkeyBinding>? stored = _shortcuts;
    return <String, dynamic>{
      'profiles': profiles
          .map((ProviderProfile item) => item.toJson())
          .toList(),
      'activeProfileId': activeProfileId,
      'activeEnrichmentProfileId': activeEnrichmentProfileId,
      'audio': audio.toJson(),
      'themeMode': themeMode.name,
      'timerMinutes': timerMinutes,
      'timerAlarm': timerAlarm.name,
      if (tursoDbUrl != null) 'tursoDbUrl': tursoDbUrl,
      if (tursoAuthToken != null) 'tursoAuthToken': tursoAuthToken,
      'tursoSyncEnabled': tursoSyncEnabled,
      if (r2Endpoint != null) 'r2Endpoint': r2Endpoint,
      if (r2Bucket != null) 'r2Bucket': r2Bucket,
      if (r2AccessKeyId != null) 'r2AccessKeyId': r2AccessKeyId,
      if (r2SecretAccessKey != null) 'r2SecretAccessKey': r2SecretAccessKey,
      'r2MediaSyncEnabled': r2MediaSyncEnabled,
      if (commandBaseUrl != null) 'commandBaseUrl': commandBaseUrl,
      if (commandToken != null) 'commandToken': commandToken,
      if (vaultPath != null) ...<String, dynamic>{
        'vaultPath': vaultPath,
        'vaultFolder': vaultFolder,
        'vaultCopySources': vaultCopySources,
      },
      if (_enrichmentInstructions != null)
        'enrichmentInstructions': _enrichmentInstructions,
      if (priceOverrides.isNotEmpty)
        'priceOverrides': <String, dynamic>{
          for (final MapEntry<String, ModelPrice> entry
              in priceOverrides.entries)
            entry.key: entry.value.toJson(),
        },
      if (_storagePrice != null) 'storagePrice': _storagePrice.toJson(),
      if (stored != null)
        'shortcuts': <String, dynamic>{
          for (final MapEntry<ShortcutAction, HotkeyBinding> entry
              in stored.entries)
            entry.key.name: entry.value.toJson(),
        },
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final dynamic rawProfiles = json['profiles'];
    final List<ProviderProfile> profiles = rawProfiles is List<dynamic>
        ? rawProfiles
              .whereType<Map<String, dynamic>>()
              .map(ProviderProfile.fromJson)
              .toList()
        : <ProviderProfile>[];

    final dynamic rawShortcuts = json['shortcuts'];
    Map<ShortcutAction, HotkeyBinding>? shortcuts;
    if (rawShortcuts is Map<String, dynamic>) {
      shortcuts = <ShortcutAction, HotkeyBinding>{};
      for (final MapEntry<String, dynamic> entry in rawShortcuts.entries) {
        final ShortcutAction? action = ShortcutAction.fromName(entry.key);
        final dynamic value = entry.value;
        if (action == null || value is! Map<String, dynamic>) continue;
        final HotkeyBinding? binding = HotkeyBinding.fromJson(value);
        if (binding != null) shortcuts[action] = binding;
      }
    }

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

    final dynamic rawAudio = json['audio'];
    return AppSettings(
      profiles: profiles,
      activeProfileId: json['activeProfileId'] is String
          ? json['activeProfileId'] as String
          : null,
      activeEnrichmentProfileId: json['activeEnrichmentProfileId'] is String
          ? json['activeEnrichmentProfileId'] as String
          : null,
      enrichmentInstructions: json['enrichmentInstructions'] is String
          ? json['enrichmentInstructions'] as String
          : null,
      audio: rawAudio is Map<String, dynamic>
          ? AudioConfig.fromJson(rawAudio)
          : AudioConfig.defaults,
      themeMode: AppThemeMode.fromName(
        json['themeMode'] is String ? json['themeMode'] as String : null,
      ),
      vaultPath: json['vaultPath'] is String
          ? json['vaultPath'] as String
          : null,
      vaultFolder: json['vaultFolder'] is String
          ? json['vaultFolder'] as String
          : VaultDefaults.folder,
      vaultCopySources: json['vaultCopySources'] is bool
          ? json['vaultCopySources'] as bool
          : true,
      timerMinutes: json['timerMinutes'] is int
          ? json['timerMinutes'] as int
          : TimerDefaults.defaultMinutes,
      timerAlarm: AlarmSound.fromName(
        json['timerAlarm'] is String ? json['timerAlarm'] as String : null,
      ),
      tursoDbUrl: json['tursoDbUrl'] is String
          ? json['tursoDbUrl'] as String
          : null,
      tursoAuthToken: json['tursoAuthToken'] is String
          ? json['tursoAuthToken'] as String
          : null,
      tursoSyncEnabled: json['tursoSyncEnabled'] is bool
          ? json['tursoSyncEnabled'] as bool
          : false,
      r2Endpoint: json['r2Endpoint'] is String
          ? json['r2Endpoint'] as String
          : null,
      r2Bucket: json['r2Bucket'] is String
          ? json['r2Bucket'] as String
          : null,
      r2AccessKeyId: json['r2AccessKeyId'] is String
          ? json['r2AccessKeyId'] as String
          : null,
      r2SecretAccessKey: json['r2SecretAccessKey'] is String
          ? json['r2SecretAccessKey'] as String
          : null,
      r2MediaSyncEnabled: json['r2MediaSyncEnabled'] is bool
          ? json['r2MediaSyncEnabled'] as bool
          : false,
      commandBaseUrl: json['commandBaseUrl'] is String
          ? json['commandBaseUrl'] as String
          : null,
      commandToken: json['commandToken'] is String
          ? json['commandToken'] as String
          : null,
      priceOverrides: priceOverrides,
      storagePrice: storagePrice,
      shortcuts: shortcuts,
    );
  }
}

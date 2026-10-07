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
import 'queue_density.dart';
import 'token_cipher.dart';

class AppSettings {
  const AppSettings({
    this.profiles = const <ProviderProfile>[],
    this.activeProfileId,
    this.activeEnrichmentProfileId,
    String? enrichmentInstructions,
    this.soulPath,
    this.autoCleanup = false,
    this.audio = AudioConfig.defaults,
    this.themeMode = AppThemeMode.system,
    this.textScale = defaultTextScale,
    this.queueDensity = QueueDensity.compact,
    this.navRailExpanded = false,
    this.vaultPath,
    this.vaultFolder = VaultDefaults.folder,
    this.vaultCopySources = true,
    this.timerMinutes = TimerDefaults.defaultMinutes,
    this.timerAlarm = AlarmSound.fallback,
    this.commandBaseUrl,
    this.commandToken,
    this.s3Endpoint,
    this.s3Bucket,
    this.s3Region,
    this.s3AccessKeyId,
    this.s3SecretAccessKey,
    this.s3Prefix,
    this.syncDeviceId,
    this.priceOverrides = const <String, ModelPrice>{},
    StoragePrice? storagePrice,
    Map<ShortcutAction, HotkeyBinding>? shortcuts,
  }) : _enrichmentInstructions = enrichmentInstructions,
       _storagePrice = storagePrice,
       _shortcuts = shortcuts;

  static const AppSettings empty = AppSettings();

  static const double defaultTextScale = 1.0;
  static const double minTextScale = 0.75;
  static const double maxTextScale = 2.0;

  static double clampTextScale(double value) {
    final double clamped = value.clamp(minTextScale, maxTextScale);
    return double.parse(clamped.toStringAsFixed(2));
  }

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

  /// A markdown file whose text replaces [enrichmentInstructions] as the
  /// user's soul, or null for the typed profile alone. Device-local, like
  /// [vaultPath]: a path means nothing on another machine. When the file is
  /// missing or unreadable the typed profile still stands in, so clearing this
  /// is never required to recover.
  final String? soulPath;

  /// Whether every finished speech or OCR capture gets a clean-up proposal
  /// (#258). Off by default — it is one more model call per capture — and
  /// written only when on, so a file that never touched it is unchanged.
  final bool autoCleanup;

  final AudioConfig audio;
  final AppThemeMode themeMode;
  final double textScale;

  /// Row height in the Queue's master list. Written only when it is not the
  /// default, so a file that never touched it serialises exactly as before.
  final QueueDensity queueDensity;

  /// Whether the wide shell's rail shows labels (220 px) or icons only
  /// (64 px, the default). Written only when expanded.
  final bool navRailExpanded;
  final String? vaultPath;
  final String vaultFolder;
  final bool vaultCopySources;

  bool get mirrorsToVault => (vaultPath ?? '').trim().isNotEmpty;

  final int timerMinutes;
  final AlarmSound timerAlarm;

  Duration get timerDuration =>
      TimerDefaults.clamp(Duration(minutes: timerMinutes));

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

  /// A uuid generated once and persisted here, never rederived — the
  /// `devices` row a Supabase sync run upserts is keyed on it, and a value
  /// that changed between runs would look like a device reinstall to the
  /// server on every launch.
  final String? syncDeviceId;

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

  final String? s3Endpoint;
  final String? s3Bucket;
  final String? s3Region;
  final String? s3AccessKeyId;
  final String? s3SecretAccessKey;
  final String? s3Prefix;

  bool get hasCustomS3Storage =>
      (s3Endpoint ?? '').trim().isNotEmpty &&
      (s3Bucket ?? '').trim().isNotEmpty &&
      (s3AccessKeyId ?? '').trim().isNotEmpty &&
      (s3SecretAccessKey ?? '').trim().isNotEmpty;

  String? get usableS3SecretAccessKey {
    final String token = s3SecretAccessKey?.trim() ?? '';
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
    String? soulPath,
    bool clearSoulPath = false,
    bool? autoCleanup,
    AudioConfig? audio,
    AppThemeMode? themeMode,
    double? textScale,
    bool resetTextScale = false,
    QueueDensity? queueDensity,
    bool? navRailExpanded,
    String? vaultPath,
    bool clearVaultPath = false,
    String? vaultFolder,
    bool? vaultCopySources,
    int? timerMinutes,
    AlarmSound? timerAlarm,
    String? commandBaseUrl,
    bool clearCommandBaseUrl = false,
    String? commandToken,
    bool clearCommandToken = false,
    String? s3Endpoint,
    bool clearS3Endpoint = false,
    String? s3Bucket,
    bool clearS3Bucket = false,
    String? s3Region,
    bool clearS3Region = false,
    String? s3AccessKeyId,
    bool clearS3AccessKeyId = false,
    String? s3SecretAccessKey,
    bool clearS3SecretAccessKey = false,
    String? s3Prefix,
    bool clearS3Prefix = false,
    String? syncDeviceId,
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
      soulPath: clearSoulPath ? null : (soulPath ?? this.soulPath),
      autoCleanup: autoCleanup ?? this.autoCleanup,
      audio: audio ?? this.audio,
      themeMode: themeMode ?? this.themeMode,
      textScale: resetTextScale
          ? defaultTextScale
          : (textScale != null ? clampTextScale(textScale) : this.textScale),
      queueDensity: queueDensity ?? this.queueDensity,
      navRailExpanded: navRailExpanded ?? this.navRailExpanded,
      vaultPath: clearVaultPath ? null : (vaultPath ?? this.vaultPath),
      vaultFolder: vaultFolder ?? this.vaultFolder,
      vaultCopySources: vaultCopySources ?? this.vaultCopySources,
      timerMinutes: timerMinutes ?? this.timerMinutes,
      timerAlarm: timerAlarm ?? this.timerAlarm,
      commandBaseUrl: clearCommandBaseUrl
          ? null
          : (commandBaseUrl ?? this.commandBaseUrl),
      commandToken: clearCommandToken
          ? null
          : (commandToken ?? this.commandToken),
      s3Endpoint: clearS3Endpoint ? null : (s3Endpoint ?? this.s3Endpoint),
      s3Bucket: clearS3Bucket ? null : (s3Bucket ?? this.s3Bucket),
      s3Region: clearS3Region ? null : (s3Region ?? this.s3Region),
      s3AccessKeyId: clearS3AccessKeyId ? null : (s3AccessKeyId ?? this.s3AccessKeyId),
      s3SecretAccessKey: clearS3SecretAccessKey ? null : (s3SecretAccessKey ?? this.s3SecretAccessKey),
      s3Prefix: clearS3Prefix ? null : (s3Prefix ?? this.s3Prefix),
      syncDeviceId: syncDeviceId ?? this.syncDeviceId,
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
      if (textScale != defaultTextScale) 'textScale': textScale,
      if (queueDensity != QueueDensity.compact)
        'queueDensity': queueDensity.name,
      if (navRailExpanded) 'navRailExpanded': true,
      'timerMinutes': timerMinutes,
      'timerAlarm': timerAlarm.name,
      if (commandBaseUrl != null) 'commandBaseUrl': commandBaseUrl,
      if (commandToken != null) 'commandToken': commandToken,
      if (s3Endpoint != null && s3Endpoint!.trim().isNotEmpty) 's3Endpoint': s3Endpoint,
      if (s3Bucket != null && s3Bucket!.trim().isNotEmpty) 's3Bucket': s3Bucket,
      if (s3Region != null && s3Region!.trim().isNotEmpty) 's3Region': s3Region,
      if (s3AccessKeyId != null && s3AccessKeyId!.trim().isNotEmpty) 's3AccessKeyId': s3AccessKeyId,
      if (s3SecretAccessKey != null && s3SecretAccessKey!.trim().isNotEmpty) 's3SecretAccessKey': s3SecretAccessKey,
      if (s3Prefix != null && s3Prefix!.trim().isNotEmpty) 's3Prefix': s3Prefix,
      if (syncDeviceId != null) 'syncDeviceId': syncDeviceId,
      if (vaultPath != null) ...<String, dynamic>{
        'vaultPath': vaultPath,
        'vaultFolder': vaultFolder,
        'vaultCopySources': vaultCopySources,
      },
      if (_enrichmentInstructions != null)
        'enrichmentInstructions': _enrichmentInstructions,
      if (soulPath != null) 'soulPath': soulPath,
      if (autoCleanup) 'autoCleanup': true,
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

    // A `storagePrice` map written before #202 holds the R2 and Turso rates
    // and nothing this build prices by. Reading it as a custom price would
    // pin the install to the shipped default with `hasCustomStoragePrice`
    // claiming the user chose it, so it reads as absent and the next write
    // drops it, the same way the retired `turso*` / `r2*` fields are dropped.
    final dynamic rawStorage = json['storagePrice'];
    final StoragePrice? storagePrice =
        rawStorage is Map<String, dynamic> &&
            StoragePrice.isReadable(rawStorage)
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
      textScale: json['textScale'] is num
          ? AppSettings.clampTextScale((json['textScale'] as num).toDouble())
          : AppSettings.defaultTextScale,
      queueDensity: QueueDensity.fromName(
        json['queueDensity'] is String ? json['queueDensity'] as String : null,
      ),
      navRailExpanded: json['navRailExpanded'] == true,
      autoCleanup: json['autoCleanup'] == true,
      soulPath: json['soulPath'] is String
          ? json['soulPath'] as String
          : null,
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
      commandBaseUrl: json['commandBaseUrl'] is String
          ? json['commandBaseUrl'] as String
          : null,
      commandToken: json['commandToken'] is String
          ? json['commandToken'] as String
          : null,
      s3Endpoint: json['s3Endpoint'] is String
          ? json['s3Endpoint'] as String
          : null,
      s3Bucket: json['s3Bucket'] is String
          ? json['s3Bucket'] as String
          : null,
      s3Region: json['s3Region'] is String
          ? json['s3Region'] as String
          : null,
      s3AccessKeyId: json['s3AccessKeyId'] is String
          ? json['s3AccessKeyId'] as String
          : null,
      s3SecretAccessKey: json['s3SecretAccessKey'] is String
          ? json['s3SecretAccessKey'] as String
          : null,
      s3Prefix: json['s3Prefix'] is String
          ? json['s3Prefix'] as String
          : null,
      syncDeviceId: json['syncDeviceId'] is String
          ? json['syncDeviceId'] as String
          : null,
      priceOverrides: priceOverrides,
      storagePrice: storagePrice,
      shortcuts: shortcuts,
    );
  }
}

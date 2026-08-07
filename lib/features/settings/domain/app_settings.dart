import '../../enrichment/domain/enrichment_defaults.dart';
import '../../recordings/domain/note_vault.dart';
import '../../shortcuts/domain/hotkey_binding.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import '../../timer/domain/alarm_sound.dart';
import '../../timer/domain/timer_defaults.dart';
import 'app_theme_mode.dart';
import 'audio_config.dart';
import 'provider_profile.dart';

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
    this.tursoDbUrl = 'libsql://augustyniak-capture-laugustyniak.aws-us-east-1.turso.io',
    this.tursoAuthToken = 'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3ODYxMDkwNDIsImlkIjoiMDE5ZmRjNjUtMTkwMS03N2JiLTk2NmMtYzQ4OGY0MmY4Y2Y5Iiwia2lkIjoiS05WbTBXMHhOZjdyd21pSXRrczdYMGdmYml3VGhGQ0RPbEtxemU4UUZmdyIsInJpZCI6IjE3MTJmZDJhLWVmY2MtNGI2MC1iZjQyLTVhMmEzNmYwYzkzYiJ9.4bvw9Cf9oMVSzDJSaZ9eq6bOTwbCXuYdast_FzKEddESgS3G3NCjjkSgJE7SRs17xtuTog42tJtrVRZ1Etl0Ag',
    this.tursoSyncEnabled = true,
    Map<ShortcutAction, HotkeyBinding>? shortcuts,
  }) : _enrichmentInstructions = enrichmentInstructions,
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
      'tursoDbUrl': tursoDbUrl,
      'tursoAuthToken': tursoAuthToken,
      'tursoSyncEnabled': tursoSyncEnabled,
      if (vaultPath != null) ...<String, dynamic>{
        'vaultPath': vaultPath,
        'vaultFolder': vaultFolder,
        'vaultCopySources': vaultCopySources,
      },
      if (_enrichmentInstructions != null)
        'enrichmentInstructions': _enrichmentInstructions,
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
          : 'libsql://augustyniak-capture-laugustyniak.aws-us-east-1.turso.io',
      tursoAuthToken: json['tursoAuthToken'] is String
          ? json['tursoAuthToken'] as String
          : 'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3ODYxMDkwNDIsImlkIjoiMDE5ZmRjNjUtMTkwMS03N2JiLTk2NmMtYzQ4OGY0MmY4Y2Y5Iiwia2lkIjoiS05WbTBXMHhOZjdyd21pSXRrczdYMGdmYml3VGhGQ0RPbEtxemU4UUZmdyIsInJpZCI6IjE3MTJmZDJhLWVmY2MtNGI2MC1iZjQyLTVhMmEzNmYwYzkzYiJ9.4bvw9Cf9oMVSzDJSaZ9eq6bOTwbCXuYdast_FzKEddESgS3G3NCjjkSgJE7SRs17xtuTog42tJtrVRZ1Etl0Ag',
      tursoSyncEnabled: json['tursoSyncEnabled'] is bool
          ? json['tursoSyncEnabled'] as bool
          : true,
      shortcuts: shortcuts,
    );
  }
}

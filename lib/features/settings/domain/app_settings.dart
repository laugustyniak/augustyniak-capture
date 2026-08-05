import '../../enrichment/domain/enrichment_defaults.dart';
import '../../shortcuts/domain/hotkey_binding.dart';
import '../../shortcuts/domain/shortcut_action.dart';
import 'app_theme_mode.dart';
import 'audio_config.dart';
import 'provider_profile.dart';

/// Everything the user can change at runtime.
///
/// Persisted as a single `settings.json` next to `recordings.json`. Like
/// `Recording.fromJson`, every field defaults when absent so older files keep
/// loading after new fields are added.
class AppSettings {
  const AppSettings({
    this.profiles = const <ProviderProfile>[],
    this.activeProfileId,
    this.activeEnrichmentProfileId,
    String? enrichmentInstructions,
    this.audio = AudioConfig.defaults,
    this.themeMode = AppThemeMode.system,
    Map<ShortcutAction, HotkeyBinding>? shortcuts,
  }) : _enrichmentInstructions = enrichmentInstructions,
       _shortcuts = shortcuts;

  static const AppSettings empty = AppSettings();

  final List<ProviderProfile> profiles;
  final String? activeProfileId;

  /// The enrichment profile in force. Independent of [activeProfileId] because
  /// one profile of each kind has to be active at the same time.
  final String? activeEnrichmentProfileId;

  /// Null means "never configured", exactly as with [_shortcuts], and the two
  /// carry the same three-state rule for the same reason.
  final String? _enrichmentInstructions;

  /// Free-form "who I am and what I collect", sent to the enrichment model with
  /// every capture.
  ///
  /// Absent from JSON — a fresh install, or a `settings.json` written before
  /// this field existed — resolves to [EnrichmentProfileDefaults.text]. Once
  /// the user touches it the stored value becomes authoritative, **including an
  /// empty one**: clearing the box is a decision to send no profile, and it has
  /// to survive a restart rather than springing the default back. That is the
  /// same distinction `shortcuts` draws between "never configured" and
  /// "deliberately unbound", and it is why this field is private and nullable
  /// while the getter never returns null.
  ///
  /// Lives here rather than on a [ProviderProfile] because it describes the
  /// *user*, not the endpoint: swapping OpenAI for a local Ollama must not lose
  /// it.
  String get enrichmentInstructions =>
      _enrichmentInstructions ?? EnrichmentProfileDefaults.text;

  /// False while the shipped default is still in force, so the UI can disable
  /// its "restore default" button — same role as [hasCustomShortcuts].
  bool get hasCustomEnrichmentInstructions => _enrichmentInstructions != null;

  final AudioConfig audio;

  /// Which palette to paint in. Written to `settings.json` unconditionally,
  /// unlike `shortcuts` and `enrichmentInstructions` — see [AppThemeMode.system]
  /// for why this one needs no "never configured" state.
  final AppThemeMode themeMode;

  /// Null means "never configured". Kept private and nullable rather than
  /// defaulted in the constructor because the default map reads
  /// `PhysicalKeyboardKey` fields and so cannot be a `const` default value.
  final Map<ShortcutAction, HotkeyBinding>? _shortcuts;

  /// Global hotkey bindings.
  ///
  /// Absent from JSON — a fresh install, or a `settings.json` written before
  /// this field existed — resolves to [ShortcutDefaults.bindings]. Once the user
  /// touches anything the map is stored in full and becomes authoritative: an
  /// action *missing* from a stored map is deliberately unbound, not defaulted
  /// back. That is what makes "clear this shortcut" survive a restart.
  ///
  /// Handed out unmodifiable — `_shortcuts` is a plain map, and callers pass it
  /// straight into the coordinator, so an in-place mutation would desync
  /// persisted state from what is registered with the OS.
  Map<ShortcutAction, HotkeyBinding> get shortcuts =>
      Map<ShortcutAction, HotkeyBinding>.unmodifiable(
        _shortcuts ?? ShortcutDefaults.bindings,
      );

  /// False while the defaults are still in force, so the UI can disable its
  /// "restore defaults" button.
  bool get hasCustomShortcuts => _shortcuts != null;

  /// Null when nothing is selected or the stored id no longer exists (profile
  /// deleted). Callers fall back to the disabled transcription service.
  ProviderProfile? get activeProfile {
    if (activeProfileId == null) return null;
    for (final ProviderProfile profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return null;
  }

  /// Null when nothing is selected or the stored id no longer exists (profile
  /// deleted). Callers fall back to the disabled enrichment service, which is
  /// what makes an unconfigured install simply leave items un-enriched.
  ProviderProfile? get activeEnrichmentProfile {
    if (activeEnrichmentProfileId == null) return null;
    for (final ProviderProfile profile in profiles) {
      if (profile.id == activeEnrichmentProfileId) return profile;
    }
    return null;
  }

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
      // Falls back to the stored *raw* value, not the getter: passing the
      // resolved default through here would silently promote an untouched
      // install to a custom one on the next unrelated save.
      enrichmentInstructions: resetEnrichmentInstructions
          ? null
          : (enrichmentInstructions ?? _enrichmentInstructions),
      audio: audio ?? this.audio,
      themeMode: themeMode ?? this.themeMode,
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
      // Omitted while untouched, for the same reason as `shortcuts`: a later
      // build that improves the default should still reach every user who never
      // wrote their own.
      if (_enrichmentInstructions != null)
        'enrichmentInstructions': _enrichmentInstructions,
      // Omitted entirely while untouched, so a later build that adds a new
      // action still ships its default to users who never edited a shortcut.
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
      // A present-but-empty map is meaningful: every shortcut cleared.
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
      // Type-checked rather than cast: a hand-edited or corrupted settings.json
      // holding a non-string here would throw out of the whole load, taking the
      // profiles and audio config with it. Same defensive shape as `profiles`
      // and `audio` above.
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
      shortcuts: shortcuts,
    );
  }
}

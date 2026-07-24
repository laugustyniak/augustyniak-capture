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
    this.audio = AudioConfig.defaults,
  });

  static const AppSettings empty = AppSettings();

  final List<ProviderProfile> profiles;
  final String? activeProfileId;
  final AudioConfig audio;

  /// Null when nothing is selected or the stored id no longer exists (profile
  /// deleted). Callers fall back to the disabled transcription service.
  ProviderProfile? get activeProfile {
    if (activeProfileId == null) return null;
    for (final ProviderProfile profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return null;
  }

  AppSettings copyWith({
    List<ProviderProfile>? profiles,
    String? activeProfileId,
    bool clearActiveProfileId = false,
    AudioConfig? audio,
  }) {
    return AppSettings(
      profiles: profiles ?? this.profiles,
      activeProfileId:
          clearActiveProfileId ? null : (activeProfileId ?? this.activeProfileId),
      audio: audio ?? this.audio,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'profiles':
            profiles.map((ProviderProfile item) => item.toJson()).toList(),
        'activeProfileId': activeProfileId,
        'audio': audio.toJson(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final dynamic rawProfiles = json['profiles'];
    final List<ProviderProfile> profiles = rawProfiles is List<dynamic>
        ? rawProfiles
            .whereType<Map<String, dynamic>>()
            .map(ProviderProfile.fromJson)
            .toList()
        : <ProviderProfile>[];

    final dynamic rawAudio = json['audio'];
    return AppSettings(
      profiles: profiles,
      activeProfileId: json['activeProfileId'] as String?,
      audio: rawAudio is Map<String, dynamic>
          ? AudioConfig.fromJson(rawAudio)
          : AudioConfig.defaults,
    );
  }
}

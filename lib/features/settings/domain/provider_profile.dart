import '../../transcription/data/transcription_service.dart';

/// A named transcription endpoint the user can switch between.
///
/// One profile is active at a time; `SettingsController` turns it into the
/// `TranscriptionService` that `RecordingsController` uses for the next job.
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.name,
    required this.endpoint,
    this.model,
    this.language,
    this.bearerToken,
  });

  final String id;
  final String name;

  /// Full transcription URL, e.g. `https://api.openai.com/v1/audio/transcriptions`.
  final String endpoint;

  /// Model form field. Required by OpenAI, ignored by servers that don't read it.
  final String? model;

  /// Optional ISO-639-1 hint (`pl`, `en`). Skips language auto-detection.
  final String? language;

  /// Stored in plaintext in the app documents directory — see the Config tab
  /// warning. Encryption is a later phase.
  final String? bearerToken;

  bool get hasEndpoint => endpoint.trim().isNotEmpty;

  /// Host shown in list rows so the user can tell profiles apart at a glance.
  String get host {
    final Uri? parsed = Uri.tryParse(endpoint);
    if (parsed == null || parsed.host.isEmpty) return endpoint;
    return parsed.host;
  }

  ProviderProfile copyWith({
    String? name,
    String? endpoint,
    String? model,
    String? language,
    String? bearerToken,
    bool clearModel = false,
    bool clearLanguage = false,
    bool clearBearerToken = false,
  }) {
    return ProviderProfile(
      id: id,
      name: name ?? this.name,
      endpoint: endpoint ?? this.endpoint,
      model: clearModel ? null : (model ?? this.model),
      language: clearLanguage ? null : (language ?? this.language),
      bearerToken: clearBearerToken ? null : (bearerToken ?? this.bearerToken),
    );
  }

  /// Build the service for this profile. Returns the disabled service when the
  /// endpoint is blank or unparseable, so a half-filled profile degrades to the
  /// "not configured" error instead of throwing at capture time.
  TranscriptionService toService() {
    final Uri? uri = hasEndpoint ? Uri.tryParse(endpoint.trim()) : null;
    if (uri == null || !uri.hasScheme) {
      return const DisabledTranscriptionService();
    }
    return HttpWhisperTranscriptionService(
      endpoint: uri,
      bearerToken: _blankToNull(bearerToken),
      model: _blankToNull(model),
      language: _blankToNull(language),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'model': model,
        'language': language,
        'bearerToken': bearerToken,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) {
    return ProviderProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Profil',
      endpoint: json['endpoint'] as String? ?? '',
      model: json['model'] as String?,
      language: json['language'] as String?,
      bearerToken: json['bearerToken'] as String?,
    );
  }

  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Starting points offered by the "add profile" sheet in the Models tab.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.endpoint,
    this.model,
    this.needsToken = true,
  });

  final String name;
  final String endpoint;
  final String? model;
  final bool needsToken;

  static const List<ProviderPreset> all = <ProviderPreset>[
    ProviderPreset(
      name: 'OpenAI Whisper',
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
    ),
    ProviderPreset(
      name: 'OpenAI GPT-4o transcribe',
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'gpt-4o-transcribe',
    ),
    ProviderPreset(
      name: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
      model: 'whisper-large-v3-turbo',
    ),
    ProviderPreset(
      name: 'Lokalny whisper.cpp',
      endpoint: 'http://localhost:8080/inference',
      needsToken: false,
    ),
    ProviderPreset(
      name: 'Własny endpoint',
      endpoint: '',
      needsToken: false,
    ),
  ];
}

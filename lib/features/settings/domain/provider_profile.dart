import '../../enrichment/data/http_chat_enrichment_service.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../../transcription/data/transcription_service.dart';

/// What a profile is *for*.
///
/// One list holds both kinds because everything else about them — name,
/// endpoint, model, token, editor UI — is identical; only the request body
/// differs, and that difference lives entirely in the two `to…Service()`
/// methods below.
enum ProfileKind {
  transcription,
  enrichment;

  /// Legacy rows have no `kind`, and every profile written before enrichment
  /// existed was a transcription profile.
  static ProfileKind fromName(String? name) =>
      ProfileKind.values.asNameMap()[name] ?? ProfileKind.transcription;

  /// Polish, for the section headers in the Models tab.
  String get label => switch (this) {
        ProfileKind.transcription => 'TRANSKRYPCJA',
        ProfileKind.enrichment => 'OPIS I KATEGORIA',
      };
}

/// A named transcription endpoint the user can switch between.
///
/// One profile is active at a time; `SettingsController` turns it into the
/// `TranscriptionService` that `RecordingsController` uses for the next job.
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.name,
    required this.endpoint,
    this.kind = ProfileKind.transcription,
    this.model,
    this.language,
    this.bearerToken,
  });

  final String id;
  final String name;

  /// Which pipeline stage this profile configures. Defaults to
  /// [ProfileKind.transcription] so every row written before enrichment existed
  /// keeps its meaning.
  final ProfileKind kind;

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
    ProfileKind? kind,
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
      kind: kind ?? this.kind,
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

  /// Build the enrichment service for this profile. Same
  /// blank-or-schemeless guard as [toService]: a half-filled profile degrades
  /// to the disabled service rather than throwing mid-pipeline.
  ///
  /// No `language` — the chat request asks the model to answer in the language
  /// of the input, so a per-profile hint would only fight it.
  EnrichmentService toEnrichmentService() {
    final Uri? uri = hasEndpoint ? Uri.tryParse(endpoint.trim()) : null;
    if (uri == null || !uri.hasScheme) {
      return const DisabledEnrichmentService();
    }
    return HttpChatEnrichmentService(
      endpoint: uri,
      bearerToken: _blankToNull(bearerToken),
      model: _blankToNull(model),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'kind': kind.name,
        'model': model,
        'language': language,
        'bearerToken': bearerToken,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) {
    return ProviderProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Profile',
      endpoint: json['endpoint'] as String? ?? '',
      kind: ProfileKind.fromName(json['kind'] as String?),
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
    this.kind = ProfileKind.transcription,
    this.model,
  });

  final String name;
  final String endpoint;

  /// Which section of the Models tab offers this preset.
  final ProfileKind kind;
  final String? model;

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
      name: 'Local whisper.cpp',
      endpoint: 'http://localhost:8080/inference',
    ),
    ProviderPreset(
      name: 'Custom endpoint',
      endpoint: '',
    ),
  ];
}

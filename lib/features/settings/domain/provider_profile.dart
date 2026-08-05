import '../../enrichment/data/http_chat_enrichment_service.dart';
import '../../enrichment/domain/enrichment_service.dart';
import '../../processing/data/http_vision_ocr_service.dart';
import '../../processing/data/ocr_service.dart';
import '../../transcription/data/transcription_service.dart';
import 'token_cipher.dart';

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

  /// Section header in the Models tab.
  String get label => switch (this) {
    ProfileKind.transcription => 'TRANSCRIPTION PROFILES',
    ProfileKind.enrichment => 'ENRICHMENT PROFILES',
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

  /// Encrypted at rest in `settings.json` when the OS keyring is available
  /// (see `TokenCipher`); plaintext otherwise, which the Config tab surfaces.
  /// In memory this is normally the plaintext value, but after a failed
  /// decrypt (keyring wiped or locked) it holds the sealed `enc:v1:` blob so
  /// the stored token is never destroyed — [usableBearerToken] filters that
  /// case out for request headers.
  final String? bearerToken;

  bool get hasEndpoint => endpoint.trim().isNotEmpty;

  /// The token a request may actually send: null when unset, blank, or still
  /// sealed because decryption failed. A sealed blob must never leak into an
  /// `Authorization` header.
  String? get usableBearerToken {
    final String? token = _blankToNull(bearerToken);
    if (token == null || TokenCipher.isSealed(token)) return null;
    return token;
  }

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
      bearerToken: usableBearerToken,
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
      bearerToken: usableBearerToken,
      model: _blankToNull(model),
    );
  }

  /// Build the image-OCR service for this profile. OCR deliberately has no
  /// profile kind of its own: it rides the **enrichment** profile, because a
  /// vision-capable chat endpoint is exactly what enrichment already talks to,
  /// and one profile configuring both stages beats a third Models-tab section.
  /// Same blank-or-schemeless guard as [toService].
  OcrService toOcrService() {
    final Uri? uri = hasEndpoint ? Uri.tryParse(endpoint.trim()) : null;
    if (uri == null || !uri.hasScheme) {
      return const DisabledOcrService();
    }
    return HttpVisionOcrService(
      endpoint: uri,
      bearerToken: usableBearerToken,
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
    this.models = const <String>[],
    this.tokenHint,
  });

  final String name;
  final String endpoint;

  /// Which section of the Models tab offers this preset.
  final ProfileKind kind;

  /// The model pre-filled when the preset is picked.
  final String? model;

  /// Known-good models for this provider, offered as suggestion chips in the
  /// editor. A static list, not a `/models` fetch: it degrades to nothing when
  /// stale, and the field stays free-text either way.
  final List<String> models;

  /// Shown under the token field so the user knows what kind of key to paste.
  final String? tokenHint;

  static const List<ProviderPreset> all = <ProviderPreset>[
    // OpenAI's current recommendation for transcribing recorded speech.
    // `gpt-4o-transcribe` and its mini variant still work but are the previous
    // generation; whisper-1 keeps its own preset below for the one property it
    // has and none of the LLM-based models do — see the note there.
    ProviderPreset(
      name: 'OpenAI transcribe',
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'gpt-transcribe',
      models: <String>[
        'gpt-transcribe',
        'gpt-4o-transcribe',
        'gpt-4o-mini-transcribe',
        'whisper-1',
      ],
      tokenHint: 'OpenAI API key (sk-…)',
    ),
    // Kept as its own preset, and not because it is older: whisper-1 is the
    // only hosted model here with **no output-token ceiling**, so on mobile —
    // where there is no ffmpeg to split with — it is the one that transcribes a
    // 50-minute capture in full. `TranscriptionLimits` encodes that difference:
    // it caps the LLM-based models at ~8 min and whisper-1 only at 25 MB.
    ProviderPreset(
      name: 'OpenAI Whisper',
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
      models: <String>['whisper-1', 'gpt-transcribe'],
      tokenHint: 'OpenAI API key (sk-…)',
    ),
    ProviderPreset(
      name: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/audio/transcriptions',
      model: 'whisper-large-v3-turbo',
      models: <String>['whisper-large-v3-turbo', 'whisper-large-v3'],
      tokenHint: 'Groq API key (gsk_…)',
    ),
    ProviderPreset(
      name: 'Local whisper.cpp',
      endpoint: 'http://localhost:8080/inference',
    ),
    ProviderPreset(name: 'Custom endpoint', endpoint: ''),
    // Enrichment presets double as OCR providers: the active enrichment
    // profile also powers image OCR, so every model listed here should be
    // vision-capable (or the provider ignores images gracefully).
    // The default is the cheapest of the current family rather than the most
    // capable one: this stage writes a title, a category, four tags and a
    // summary from at most 12 000 characters, and it runs on every capture.
    // The frontier models are listed for anyone who wants them.
    ProviderPreset(
      name: 'OpenAI',
      kind: ProfileKind.enrichment,
      endpoint: 'https://api.openai.com/v1/chat/completions',
      model: 'gpt-5.6-luna',
      models: <String>[
        'gpt-5.6-luna',
        'gpt-5.6-terra',
        'gpt-5.6-sol',
        'gpt-4o-mini',
      ],
      tokenHint: 'OpenAI API key (sk-…)',
    ),
    ProviderPreset(
      name: 'Anthropic',
      kind: ProfileKind.enrichment,
      // Anthropic's OpenAI-compatible endpoint — same request shape as the
      // rest, so no dedicated adapter is needed. Two caveats that only bite
      // here: the compatibility layer **ignores `response_format`**, so the
      // JSON contract rests entirely on the prompt (which is why
      // `_stripFence` and the field-by-field degrade in the parser matter more
      // for this provider than for OpenAI); and `image_url` data URLs *are*
      // supported, so the OCR path this profile also powers works.
      endpoint: 'https://api.anthropic.com/v1/chat/completions',
      model: 'claude-haiku-4-5',
      models: <String>[
        'claude-haiku-4-5',
        'claude-sonnet-5',
        'claude-opus-5',
        'claude-fable-5',
      ],
      tokenHint: 'Anthropic API key (sk-ant-…)',
    ),
    // Groq's production line-up has no vision model, so this profile enriches
    // text well and cannot do OCR — an image capture on it lands `failed`,
    // retryable, with the source intact. Pick OpenAI, Anthropic or a local
    // vision model if you capture images.
    ProviderPreset(
      name: 'Groq chat',
      kind: ProfileKind.enrichment,
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      model: 'llama-3.3-70b-versatile',
      models: <String>[
        'llama-3.3-70b-versatile',
        'openai/gpt-oss-120b',
        'openai/gpt-oss-20b',
      ],
      tokenHint: 'Groq API key (gsk_…)',
    ),
    ProviderPreset(
      name: 'Local Ollama',
      kind: ProfileKind.enrichment,
      endpoint: 'http://localhost:11434/v1/chat/completions',
      model: 'qwen2.5vl',
      models: <String>['qwen2.5vl', 'llama3.2-vision', 'gemma3', 'llava'],
    ),
    ProviderPreset(
      name: 'Custom endpoint',
      kind: ProfileKind.enrichment,
      endpoint: '',
    ),
  ];
}

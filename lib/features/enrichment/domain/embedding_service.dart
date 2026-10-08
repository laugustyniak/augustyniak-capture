/// Turns a capture's text into a vector, so captures can be compared by
/// meaning rather than by shared words (#272).
///
/// Same seam shape as `EnrichmentService`: the real implementation calls an
/// OpenAI-compatible `/v1/embeddings` on the enrichment profile's endpoint, and
/// the default throws at use, so an unconfigured install still captures and
/// only the RELATED section is missing.
abstract interface class EmbeddingService {
  /// The model that produced the vectors. Two models' vectors live in
  /// different spaces, so every stored vector carries this and is only ever
  /// compared with vectors from the same model. Empty means disabled.
  String get model;

  Future<List<double>> embed(String text);
}

class EmbeddingNotConfiguredException implements Exception {
  const EmbeddingNotConfiguredException();

  @override
  String toString() =>
      'Set an embedding model in Config to find related captures.';
}

class DisabledEmbeddingService implements EmbeddingService {
  const DisabledEmbeddingService();

  @override
  String get model => '';

  @override
  Future<List<double>> embed(String text) async =>
      throw const EmbeddingNotConfiguredException();
}

/// The `/embeddings` endpoint next to a chat endpoint, or null when [chat]
/// does not end in `/chat/completions` — guessing a path for an unknown server
/// would send the transcript somewhere nobody configured.
Uri? embeddingsEndpointFor(Uri chat) {
  const String suffix = '/chat/completions';
  final String path = chat.path.endsWith('/')
      ? chat.path.substring(0, chat.path.length - 1)
      : chat.path;
  if (!path.endsWith(suffix)) return null;
  return chat.replace(
    path: '${path.substring(0, path.length - suffix.length)}/embeddings',
  );
}

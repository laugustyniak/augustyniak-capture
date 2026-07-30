import 'enrichment_result.dart';

/// Turns processor-output text into a title, a category, a summary and tags.
///
/// Same shape as `TranscriptionService`: an interface, a disabled default that
/// throws, and one HTTP implementation. The default is what an unconfigured
/// install gets, and because the caller treats enrichment as best-effort, that
/// install simply ends up with un-enriched items rather than errors.
abstract interface class EnrichmentService {
  Future<EnrichmentResult> enrich(String text);
}

class DisabledEnrichmentService implements EnrichmentService {
  const DisabledEnrichmentService();

  @override
  Future<EnrichmentResult> enrich(String text) async {
    throw const EnrichmentNotConfiguredException();
  }
}

class EnrichmentNotConfiguredException implements Exception {
  const EnrichmentNotConfiguredException();

  @override
  String toString() => 'Enrichment endpoint is not configured.';
}

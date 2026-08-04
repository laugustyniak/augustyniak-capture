import 'enrichment_context.dart';
import 'enrichment_result.dart';

/// Turns processor-output text into a title, a category, a summary and tags.
///
/// Same shape as `TranscriptionService`: an interface, a disabled default that
/// throws, and one HTTP implementation. The default is what an unconfigured
/// install gets, and because the caller treats enrichment as best-effort, that
/// install simply ends up with un-enriched items rather than errors.
abstract interface class EnrichmentService {
  /// [context] carries the user's profile and the capture's project
  /// description. It is per-*call* rather than per-service because it varies by
  /// item — two captures enriched by the same endpoint can belong to different
  /// projects — which is also why it cannot live in the profile the way the
  /// endpoint and model do.
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  });
}

class DisabledEnrichmentService implements EnrichmentService {
  const DisabledEnrichmentService();

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    throw const EnrichmentNotConfiguredException();
  }
}

class EnrichmentNotConfiguredException implements Exception {
  const EnrichmentNotConfiguredException();

  @override
  String toString() => 'Enrichment endpoint is not configured.';
}

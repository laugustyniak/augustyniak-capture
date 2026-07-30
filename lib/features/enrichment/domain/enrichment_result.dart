import '../../recordings/domain/capture_category.dart';

/// What the enrichment model returned, after validation.
///
/// Every field is optional-ish on purpose: a model that returns a usable
/// category but a blank title should still produce a usable result. The caller
/// treats the whole stage as best-effort, so a partial result beats an
/// exception.
class EnrichmentResult {
  const EnrichmentResult({
    this.title,
    this.category = CaptureCategory.capture,
    this.summary,
    this.tags = const <String>[],
  });

  /// Null when the model returned nothing usable. The caller then leaves the
  /// item's existing title alone.
  final String? title;

  /// Never null — an unknown or missing label lands on
  /// [CaptureCategory.capture] rather than making the whole call a failure.
  final CaptureCategory category;

  final String? summary;

  /// Lowercase, deduped, at most five.
  final List<String> tags;
}

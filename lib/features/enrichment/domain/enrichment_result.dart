import '../../recordings/domain/capture_category.dart';
import '../../recordings/domain/capture_priority.dart';
import '../../recordings/domain/suggested_route.dart';

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
    this.priority,
    this.priorityReason,
    this.projectId,
    bool? projectAnswered,
    this.routeKind,
    this.routeReason,
    bool? routeAnswered,
  }) : projectAnswered = projectAnswered ?? projectId != null,
       routeAnswered = routeAnswered ?? routeKind != null;

  /// Null when the model returned nothing usable. The caller then leaves the
  /// item's existing title alone.
  final String? title;

  /// Never null — an unknown or missing label lands on
  /// [CaptureCategory.capture] rather than making the whole call a failure.
  final CaptureCategory category;

  final String? summary;

  /// Lowercase, deduped, at most five.
  final List<String> tags;

  /// Null when the model gave no usable rank. Unlike [category] there is no
  /// fallback value: an invented rank would be a judgement nobody made.
  final CapturePriority? priority;

  /// Always null when [priority] is: a reason for no rank explains nothing.
  final String? priorityReason;

  /// The id the model picked from the offered project list, or null when it
  /// named none. Not validated here: the caller checks it against the live
  /// list, which may have changed during the request.
  final String? projectId;

  /// True only when the reply carried a `project` key holding a string or an
  /// explicit null. A reply that omitted the key, or sent something else, said
  /// nothing about the project and must not clear a stamp.
  final bool projectAnswered;

  /// The destination the model proposed, or null when it said nothing usable.
  /// An explicit [SuggestedRouteKind.none] is an answer, not an absence. Not
  /// validated here: the caller checks it against what the item can really do.
  final SuggestedRouteKind? routeKind;

  /// Why, in the model's words. Only ever set alongside a [routeKind].
  final String? routeReason;

  /// True only when the reply carried a usable `route`: a known kind, or an
  /// explicit null (meaning none). A missing key or an invented kind says
  /// nothing and must not touch a stored suggestion.
  final bool routeAnswered;
}

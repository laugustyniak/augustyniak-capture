import '../../recordings/domain/capture_category.dart';
import '../../recordings/domain/suggested_route.dart';

/// Everything a [CapturePolicy] may look at, and nothing else — so a decision
/// can be replayed from its logged facts.
class CaptureFacts {
  const CaptureFacts({
    required this.category,
    required this.projectId,
    required this.availableRouteKinds,
    required this.modelRoute,
  });

  /// Null while enrichment has never classified the capture.
  final CaptureCategory? category;
  final String? projectId;

  /// What the entry points would perform for the capture right now, as the
  /// controller's `availableRouteKinds` answers it.
  final List<SuggestedRouteKind> availableRouteKinds;

  /// The kind the enrichment model answered, `none` included; null when it
  /// gave no usable answer.
  final SuggestedRouteKind? modelRoute;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'category': ?category?.name,
    'projectId': ?projectId,
    'availableRouteKinds': <String>[
      for (final SuggestedRouteKind kind in availableRouteKinds) kind.name,
    ],
    'modelRoute': ?modelRoute?.name,
  };
}

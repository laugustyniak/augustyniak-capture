import 'capture_category.dart';
import 'route_record.dart';

/// Everything a destination needs to write a capture down, flattened off the
/// `Recording` so this layer does not depend on the whole item — and so a
/// router can be tested without building one.
class RoutedCapture {
  const RoutedCapture({
    required this.projectId,
    required this.title,
    required this.body,
    required this.capturedAt,
    this.summary,
    this.category,
    this.tags = const <String>[],
  });

  final String? projectId;

  /// Already resolved by the caller — the item's own title when it has one, and
  /// the card's fallback name when it does not. A destination must never have
  /// to reimplement that cascade.
  final String title;

  /// The processor output: transcript, OCR text, or the note body.
  final String body;

  final DateTime capturedAt;
  final String? summary;
  final CaptureCategory? category;
  final List<String> tags;
}

/// Sends a capture somewhere outside the queue.
///
/// A seam for the same reason as `ClipboardSink` and `EnrichmentContextSource`:
/// the real implementation writes to the user's disk, and the pure-Dart suites
/// must be able to exercise the controller without touching one. The default
/// can route nothing, so an install that has configured no project behaves
/// exactly as it did before this existed.
abstract interface class CaptureRouter {
  /// Whether this capture has anywhere to go.
  ///
  /// Synchronous on purpose: the card gates its button on this inside `build`,
  /// and an async answer would mean either a flickering button or a probe on
  /// every frame. Destinations are configuration, not state — the answer only
  /// changes when a project does.
  bool canRoute(String? projectId);

  /// Throws on failure. The caller marks nothing and records nothing when it
  /// does: a half-delivered capture that had been ticked off as routed is the
  /// one outcome worse than a capture that was never routed at all.
  Future<RouteRecord> route(RoutedCapture capture);
}

class DisabledCaptureRouter implements CaptureRouter {
  const DisabledCaptureRouter();

  @override
  bool canRoute(String? projectId) => false;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    throw const CaptureRoutingUnavailableException();
  }
}

class CaptureRoutingUnavailableException implements Exception {
  const CaptureRoutingUnavailableException();

  @override
  String toString() =>
      'This capture has no destination — assign it to a project first.';
}

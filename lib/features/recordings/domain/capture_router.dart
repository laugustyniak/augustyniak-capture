import 'capture_category.dart';
import 'capture_type.dart';
import 'route_record.dart';

/// Everything a destination needs to write a capture down, flattened off the
/// `Recording` so this layer does not depend on the whole item — and so a
/// router can be tested without building one.
class RoutedCapture {
  const RoutedCapture({
    required this.id,
    required this.projectId,
    required this.title,
    required this.body,
    required this.capturedAt,
    required this.type,
    this.summary,
    this.category,
    this.tags = const <String>[],
  });

  /// The capture's own id.
  ///
  /// It was deliberately absent while `inbox.md` was the only destination — an
  /// inbox entry has no identity to keep — and it is here now because a second
  /// destination needs one: the control plane keys a brief on `capture_id` so
  /// that a retried delivery updates the brief it already has rather than
  /// filing a second one. `AgentHandoffRequest.captureId` now reads through to
  /// this rather than carrying its own copy.
  final String id;

  final String? projectId;

  /// What was captured — dictation, an upload, a photograph, a typed note.
  ///
  /// Required rather than defaulted, unlike every persisted type in this app.
  /// `CaptureType.fromName` defaults because it reads rows written before the
  /// field existed and has to answer *something*; this object is built fresh on
  /// every delivery, so a default here could only ever mean "the caller forgot",
  /// and the value it would invent — `audioRecording` — is the one that reads
  /// as a plain fact rather than as a gap. A brief claiming a typed note was
  /// dictated is worse than a brief that will not compile.
  final CaptureType type;

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

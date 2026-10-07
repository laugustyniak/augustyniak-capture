import 'assistant_target.dart';
import 'capture_router.dart';
import 'route_record.dart';

/// One place the **Send to…** sheet can put a capture's text.
///
/// A sealed class rather than an enum because one of the three kinds carries
/// data. Value equality matters: the sheet and the tests compare targets.
sealed class SendTarget {
  const SendTarget();
}

/// A named assistant reached through a link — see [AssistantTarget].
final class AssistantSendTarget extends SendTarget {
  const AssistantSendTarget(this.target);

  final AssistantTarget target;

  @override
  bool operator ==(Object other) =>
      other is AssistantSendTarget && other.target == target;

  @override
  int get hashCode => Object.hash(AssistantSendTarget, target);
}

/// The system share sheet, which reaches every assistant app the user has
/// installed, including ones this app has never heard of.
final class ShareSendTarget extends SendTarget {
  const ShareSendTarget();

  @override
  bool operator ==(Object other) => other is ShareSendTarget;

  @override
  int get hashCode => (ShareSendTarget).hashCode;
}

/// Copy the prompt and do nothing else.
final class CopySendTarget extends SendTarget {
  const CopySendTarget();

  @override
  bool operator ==(Object other) => other is CopySendTarget;

  @override
  int get hashCode => (CopySendTarget).hashCode;
}

/// What a completed send leaves behind.
class SendOutcome {
  const SendOutcome({required this.record, required this.copiedToClipboard});

  /// Where the capture went. **Delivery is unconfirmed** — see
  /// [RouteKind.assistant] — so recording it is not a reason to close the
  /// capture.
  final RouteRecord record;

  /// True when the prompt is on the clipboard and the user still has to paste
  /// it: Gemini has no prefill, and a prompt past a URL limit is never
  /// truncated to fit. The sheet says so; without it the user opens an empty
  /// box and has no way to know why.
  final bool copiedToClipboard;
}

/// Puts a capture's text in front of a general-purpose assistant.
///
/// The queue's fourth way out, beside [CaptureRouter], `AgentHandoff` and the
/// Command router. A separate seam because it needs no project and no
/// repository, and because its destinations are the platform's, not the
/// project's. Same shape as the others: an interface here, a default that
/// degrades, the real implementation in `data/`.
abstract interface class CaptureSender {
  /// Targets this platform can reach, in the order the sheet lists them.
  ///
  /// Asynchronous because "is a `claude://` handler registered" is a question
  /// for the OS. Never throws — a probe that fails answers "not available".
  Future<List<SendTarget>> availableTargets();

  /// Delivers [prompt] — the sheet's editable text, not a recomputation — to
  /// [target].
  ///
  /// Throws on failure, under the same contract as [CaptureRouter.route]: the
  /// caller must record nothing when it does.
  ///
  /// **Returns null when the user dismissed the share sheet**, which is neither
  /// a failure nor a send: there is nothing to report and nothing to record. A
  /// null return was chosen over a `SendDismissedException` because dismissing
  /// is an ordinary answer the user gave, and an exception would put an error
  /// line on the screen for something that went exactly as they wanted.
  Future<SendOutcome?> send(
    RoutedCapture capture,
    SendTarget target,
    String prompt,
  );
}

/// The default: nowhere to send, and a throw if anyone tries.
///
/// Throws at use rather than at wiring, so an unconfigured install — and every
/// test that never sends — still captures.
class DisabledCaptureSender implements CaptureSender {
  const DisabledCaptureSender();

  @override
  Future<List<SendTarget>> availableTargets() async => const <SendTarget>[];

  @override
  Future<SendOutcome?> send(
    RoutedCapture capture,
    SendTarget target,
    String prompt,
  ) async {
    throw const CaptureSenderUnavailableException();
  }
}

class CaptureSenderUnavailableException implements Exception {
  const CaptureSenderUnavailableException();

  @override
  String toString() => 'Sending is not available in this build.';
}

/// A link that no application accepted, so nothing was opened.
class AssistantUnavailableException implements Exception {
  const AssistantUnavailableException(this.target);

  final AssistantTarget target;

  @override
  String toString() =>
      'Could not open ${target.label} (${target.domain}). Nothing was sent.';
}

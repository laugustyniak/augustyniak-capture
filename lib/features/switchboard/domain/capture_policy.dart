import 'capture_facts.dart';
import 'decision.dart';

/// Decides, deterministically and without IO, where a saved capture goes next.
///
/// Null means "no decision" — notably when enrichment never classified the
/// capture, which is not the same fact as deciding `none`.
abstract class CapturePolicy {
  Decision? decide(CaptureFacts facts);
}

/// The default: decides nothing, so an unconfigured install behaves exactly as
/// it did before the policy existed.
class DisabledCapturePolicy implements CapturePolicy {
  const DisabledCapturePolicy();

  @override
  Decision? decide(CaptureFacts facts) => null;
}

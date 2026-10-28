import 'package:flutter/widgets.dart';

import '../../../app/ui_kit.dart';
import '../domain/smart_route.dart';
import 'recordings_controller.dart';

/// The SMART route button's whole behaviour, shared by the card, the focus
/// view and the project sheet so they cannot drift.
///
/// Classifies and delivers in one call. Only under `confirmEffects` and only
/// for an intent with effects does it stop and ask: one line naming the
/// decision, one tap to go ahead. Failures are not handled here — they land in
/// `RecordingsController.error`, which the Queue renders.
Future<void> runSmartRoute(
  BuildContext context,
  RecordingsController controller,
  String id,
) async {
  final SmartRouteOutcome? outcome = await controller.smartRoute(id);
  if (outcome == null || !outcome.awaitingConfirmation) return;
  if (!context.mounted) return;
  final SmartIntent intent = outcome.decision.intent;
  final String? reason = outcome.decision.reason;
  final bool go = await confirmDestructive(
    context,
    title: '${intent.label}?',
    message: reason == null || reason.isEmpty
        ? 'This capture reads as a request for ${intent.label.toLowerCase()}.'
        : reason,
    confirmLabel: 'RUN',
    destructive: false,
  );
  if (!go) return;
  await controller.smartRoute(id, confirmed: intent);
}

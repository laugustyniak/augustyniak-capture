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
  final String message = smartConfirmMessage(outcome);
  final bool go = await confirmDestructive(
    context,
    title: '${intent.label}?',
    message: message,
    confirmLabel: 'RUN',
    destructive: false,
  );
  if (!go) return;
  await controller.confirmSmartRoute(id, intent, expectedText: outcome.text);
}

/// What the confirmation dialog says. The sentence is ours: the intent's fixed
/// description and the agent that would run. The model's `reason`, when a model
/// wrote it, is shown after it and labelled — it is context, never the thing
/// the user is asked to approve.
String smartConfirmMessage(SmartRouteOutcome outcome) {
  final String? agent = outcome.agentLabel;
  final String? reason = outcome.decision.fromModel
      ? outcome.decision.reason
      : null;
  return '${outcome.decision.intent.description}'
      '${agent == null ? '' : ' with $agent'}.'
      '${reason == null || reason.isEmpty ? '' : '\n\nModel-suggested reason: $reason'}';
}

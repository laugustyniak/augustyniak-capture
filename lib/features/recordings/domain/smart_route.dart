/// What a capture is asking for, as the SMART route button reads it (#386).
///
/// The set is closed on purpose. A classifier (a model, or the offline keyword
/// fallback) may only **select** one of these values; it never supplies a
/// command, a path or an argument. Everything an intent does is spelled out in
/// code: [note] goes through `RecordingsController.route`, the rest launch an
/// agent with a fixed [directive], and [todoist] launches the agent command the
/// user configured.
enum SmartIntent {
  /// A loose note: file it where the project's captures go.
  note,

  /// Start the text as a fully new agent session.
  newSession,

  /// Search for information relevant to the text.
  search,

  /// Run an analysis.
  analyze,

  /// Propose the next actions.
  nextActions,

  /// Add a way to verify the information.
  verify,

  /// Perform a concrete action in Todoist (add a task). Needs the Config
  /// setting `todoistAgentCommand`; without it this intent is never offered.
  todoist;

  /// Null for an unknown name. The caller turns that into [note].
  static SmartIntent? fromName(Object? name) {
    for (final SmartIntent intent in SmartIntent.values) {
      if (intent.name == name) return intent;
    }
    return null;
  }

  /// Short label for the decision line and the route target.
  String get label => switch (this) {
    SmartIntent.note => 'Inbox',
    SmartIntent.newSession => 'New session',
    SmartIntent.search => 'Search',
    SmartIntent.analyze => 'Analysis',
    SmartIntent.nextActions => 'Next actions',
    SmartIntent.verify => 'Verification',
    SmartIntent.todoist => 'Todoist',
  };

  /// Every intent except [note] starts a process that has tools, so under
  /// [SmartRouteConfirm.confirmEffects] each of them waits for one tap.
  bool get hasEffects => this != SmartIntent.note;

  /// The trusted task line placed **above** the capture's fence in the agent's
  /// opening prompt. A fixed table in code: the model chooses a row, it never
  /// writes one. Null for [note], which launches nothing.
  String? get directive => switch (this) {
    SmartIntent.note => null,
    SmartIntent.newSession =>
      'Start this as a fresh working session. Treat the capture below as the '
          'opening brief: restate the goal in one sentence, then begin.',
    SmartIntent.search =>
      'Search for information relevant to the capture below. Report what you '
          'found, with sources, and change nothing.',
    SmartIntent.analyze =>
      'Analyse the subject of the capture below. Report your findings, the '
          'trade-offs and a conclusion. Do not change any files.',
    SmartIntent.nextActions =>
      'Propose the next concrete actions for the capture below, in order, each '
          'with a reason. Do not carry them out.',
    SmartIntent.verify =>
      'Work out how to verify the information in the capture below: list its '
          'claims, say how each can be checked, and check what you can. Cite '
          'sources and mark anything you could not confirm.',
    SmartIntent.todoist =>
      'Use your Todoist tools to create the task or tasks the capture below '
          'describes, with the due date and project where it names them. '
          'Create nothing it does not describe, and reply with what you '
          'created.',
  };
}

/// What the classifier answered. [reason] is one short line shown to the user;
/// it comes from a model steered by untrusted text, so it is sanitised and
/// bounded before it is stored here.
class SmartIntentDecision {
  const SmartIntentDecision({
    required this.intent,
    this.reason,
    this.fromModel = false,
  });

  static const int maxReasonChars = 160;

  final SmartIntent intent;
  final String? reason;

  /// False when the offline keyword fallback decided.
  final bool fromModel;
}

/// Whether a side-effecting intent waits for one tap (#386).
enum SmartRouteConfirm {
  /// Classify and deliver with no question. The default.
  auto,

  /// Show a one-line decision for every intent with effects and wait for a tap.
  confirmEffects;

  /// Unknown names degrade to the default, like every settings enum.
  static SmartRouteConfirm fromName(Object? name) {
    for (final SmartRouteConfirm value in SmartRouteConfirm.values) {
      if (value.name == name) return value;
    }
    return SmartRouteConfirm.auto;
  }
}

/// What the SMART route did with one tap.
class SmartRouteOutcome {
  const SmartRouteOutcome({
    required this.decision,
    this.delivered = false,
    this.awaitingConfirmation = false,
  });

  final SmartIntentDecision decision;

  /// The capture was delivered. False with [awaitingConfirmation] false means
  /// delivery failed and `RecordingsController.error` says why.
  final bool delivered;

  /// `confirmEffects` held an intent with effects for one tap. Nothing was
  /// delivered and the capture is exactly as it was.
  final bool awaitingConfirmation;
}

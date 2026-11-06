import '../../recordings/domain/route_record.dart';

/// Spoken review of what an agent made of a capture (#252).
///
/// Three seams, all optional, all degrading to the card view that already
/// shows an outcome: a notification when an outcome changes into a state worth
/// a look, a speaker that reads a short summary of it, and a reply that is
/// nothing more than a recording appended to the same capture through the
/// existing append path.
///
/// **What may be said is fixed here, and it is never the capture.** The
/// summary is built from the [RouteOutcome] and nothing else — the state, the
/// pull request's repository and number, how many issues were planned. A
/// notification can land on a lock screen or a paired watch, and the speaker
/// can be a cloud voice on some platforms; neither is a place the user's
/// dictated text has ever been sent, so neither becomes one.

/// Whether a change *into* [state] is worth interrupting the user for.
///
/// `done` is terminal, `blocked` and `needsReview` are waiting on a person.
/// The working states move on their own and are left to the card.
bool outcomeNeedsAttention(CommandState state) => switch (state) {
  CommandState.done || CommandState.blocked || CommandState.needsReview => true,
  CommandState.submitted ||
  CommandState.planned ||
  CommandState.inProgress => false,
};

/// A short sentence about [route]'s outcome, for a notification body or the
/// speaker. Empty-safe: a route with no outcome reads as having no news.
String spokenOutcomeSummary(RouteRecord route) {
  final RouteOutcome? outcome = route.outcome;
  if (outcome == null) return 'No news from the agent yet.';
  final List<String> parts = <String>[
    'Agent result: ${_spokenState(outcome.state)}.',
  ];
  final String? pr = outcome.prUrl;
  if (pr != null) parts.add('${_spokenPullRequest(pr)}.');
  final int issues = outcome.issues.length;
  if (issues > 0) {
    parts.add('$issues ${issues == 1 ? 'issue' : 'issues'} planned.');
  }
  return parts.join(' ');
}

String _spokenState(CommandState state) => switch (state) {
  CommandState.submitted => 'submitted',
  CommandState.planned => 'planned',
  CommandState.inProgress => 'in progress',
  CommandState.done => 'done',
  CommandState.blocked => 'blocked',
  CommandState.needsReview => 'needs review',
};

/// `https://github.com/acme/repo/pull/7` → `Pull request 7 in acme/repo`.
///
/// Anything that does not have that shape is "a pull request", never the raw
/// string: a URL read aloud is noise, and an unreadable one may not be a URL.
String _spokenPullRequest(String url) {
  final Uri? parsed = Uri.tryParse(url);
  final List<String> segments =
      parsed == null || !parsed.hasScheme || parsed.host.isEmpty
      ? const <String>[]
      : parsed.pathSegments.where((String s) => s.isNotEmpty).toList();
  if (segments.length >= 4 &&
      (segments[2] == 'pull' || segments[2] == 'pulls') &&
      int.tryParse(segments[3]) != null) {
    return 'Opened pull request ${segments[3]} in '
        '${segments[0]}/${segments[1]}';
  }
  return 'Opened a pull request';
}

/// What a notification shows about one capture's outcome.
class OutcomeAnnouncement {
  const OutcomeAnnouncement({
    required this.recordingId,
    required this.state,
    required this.summary,
  });

  /// Which capture to open when the notification is tapped, and which one a
  /// Reply action appends to.
  final String recordingId;

  final CommandState state;

  /// [spokenOutcomeSummary] — never capture text.
  final String summary;

  String get title => 'Agent ${_spokenState(state)}';
}

/// Shows an [OutcomeAnnouncement] where the user will see it.
///
/// A best-effort sink: called after the outcome is persisted, its failure is
/// swallowed, and answering false (no permission, no platform support) leaves
/// the outcome on the card where it already was.
abstract class OutcomeNotifier {
  Future<bool> notify(OutcomeAnnouncement announcement);
}

class NoopOutcomeNotifier implements OutcomeNotifier {
  const NoopOutcomeNotifier();

  @override
  Future<bool> notify(OutcomeAnnouncement announcement) async => false;
}

/// Reads a summary aloud with the platform's text-to-speech.
abstract class OutcomeSpeaker {
  /// False when there is no engine or no permission — the Listen action is
  /// then simply not offered.
  Future<bool> isAvailable();

  Future<void> speak(String text);
}

class UnavailableOutcomeSpeaker implements OutcomeSpeaker {
  const UnavailableOutcomeSpeaker();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> speak(String text) async =>
      throw UnsupportedError('No text-to-speech on this build.');
}

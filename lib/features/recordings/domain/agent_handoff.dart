import 'capture_router.dart';
import 'route_record.dart';

/// One agent a capture can be handed to, as the queue sees it.
///
/// [id] is deliberately an opaque string rather than the projects feature's
/// `AgentKind`. `ProjectInboxRouter` already makes `recordings` depend on
/// `projects`; letting this layer import it back would close the cycle. The
/// queue only needs to know that named agents exist and which one a project
/// prefers — the mapping back to an executable is owned by the implementation
/// in `data/`, the same way `ProjectAgent.executable` owns the command name.
class HandoffAgent {
  const HandoffAgent({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  final String id;
  final String label;

  /// The project's configured default. Preselected by the sheet, so launching
  /// the usual agent stays a single tap.
  final bool isDefault;
}

class AgentHandoffRequest {
  const AgentHandoffRequest({
    required this.capture,
    required this.agentId,
    required this.instruction,
  });

  /// Names the brief this capture owns, so a second handoff appends to the same
  /// file instead of scattering one task across several.
  ///
  /// Read through to [RoutedCapture.id] rather than carried beside it. It was a
  /// field of its own while `RoutedCapture` had no identity — see there for why
  /// it has one now — and two copies of one id is a drift waiting for the day
  /// a caller fills in only one of them.
  String get captureId => capture.id;

  final RoutedCapture capture;

  /// Chosen at launch time, not read off the project. Which agent should pick a
  /// task up is a property of the task, and the project's default is only the
  /// starting answer.
  final String agentId;

  /// The opening prompt, carrying the capture's own text — see
  /// [AgentHandoff.promptFor].
  final String instruction;
}

class AgentHandoffResult {
  const AgentHandoffResult({
    required this.record,
    required this.taskPath,
    required this.sessionName,
    required this.attachedToExistingSession,
  });

  final RouteRecord record;

  /// Repository-relative path of the brief that was written.
  final String taskPath;

  final String sessionName;

  /// True when the agent was already running and the session was merely
  /// reattached.
  ///
  /// **The caller has to surface this.** A multiplexer attaches to a live
  /// session; it does not deliver a new prompt to the process already running
  /// inside it. The brief is on disk either way, so nothing is lost — but the
  /// user has to be told to point the running agent at it, or they will wait
  /// for work that was never requested.
  final bool attachedToExistingSession;
}

/// Starts a coding agent on a capture, in its project's repository.
///
/// The second destination behind the queue, alongside [CaptureRouter], and a
/// separate seam rather than a second `CaptureRouter` implementation because
/// the two answer different questions: a router has one destination per
/// capture and needs no input, while this one offers a *choice* of agents and
/// takes an editable prompt. Folding them together would have meant a
/// `route(capture, {agent, prompt})` whose arguments are meaningless for the
/// inbox.
abstract interface class AgentHandoff {
  /// Agents this capture can be handed to, empty when it has nowhere to go.
  ///
  /// Synchronous for the same reason as [CaptureRouter.canRoute]: the card
  /// gates its button on this inside `build`. Destinations are configuration,
  /// not state.
  List<HandoffAgent> agentsFor(String? projectId);

  /// Repository-relative path of the brief [handoff] will write for [captureId].
  ///
  /// Deterministic and synchronous so the sheet can show the exact instruction
  /// before anything has been written, and so a second handoff of the same
  /// capture lands in the same file rather than scattering briefs.
  String taskPathFor(String captureId);

  /// The default opening prompt: **the capture's own text**, so the agent
  /// starts on the task itself rather than on an errand to go and read it.
  ///
  /// This used to be one line naming [taskPathFor], on the reasoning that a
  /// dictated note — newlines, quotes, kilobytes of it — could not survive KDL
  /// escaping, an `--args` hand-off and the agent's own argument parsing, and
  /// that each of those layers fails by silently truncating. Two of the three
  /// links turned out to be sound: Ghostty passes an `-e` argument vector
  /// through verbatim, multi-line values included, and the Zellij layout is now
  /// written to a file, which takes the whole prompt out of `ARG_MAX` as well.
  /// What the pointer cost was the thing the handoff is for — a session opened
  /// on an instruction to read a file is a session waiting for a second turn.
  ///
  /// The brief is still written to [taskPathFor], and that is not redundancy:
  /// it is what an *attach* falls back on, since a running agent never receives
  /// this prompt, and it is the copy that outlives the session.
  String promptFor(RoutedCapture capture);

  /// Writes the brief, then starts (or reattaches to) the agent's session.
  ///
  /// Throws on failure, under the same contract as [CaptureRouter.route]: the
  /// caller must record nothing when it does.
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request);
}

/// The default: no agent can be started, so the queue offers no such control.
class DisabledAgentHandoff implements AgentHandoff {
  const DisabledAgentHandoff();

  @override
  List<HandoffAgent> agentsFor(String? projectId) => const <HandoffAgent>[];

  @override
  String taskPathFor(String captureId) => '';

  @override
  String promptFor(RoutedCapture capture) => '';

  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async {
    throw const AgentHandoffUnavailableException();
  }
}

class AgentHandoffUnavailableException implements Exception {
  const AgentHandoffUnavailableException();

  @override
  String toString() =>
      'No agent session can be started for this capture — assign it to a '
      'project with a repository first.';
}

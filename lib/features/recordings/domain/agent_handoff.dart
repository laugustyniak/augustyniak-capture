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
    required this.captureId,
    required this.capture,
    required this.agentId,
    required this.instruction,
  });

  /// Names the brief this capture owns, so a second handoff appends to the same
  /// file instead of scattering one task across several. Carried beside
  /// [capture] rather than added to `RoutedCapture`, which is deliberately the
  /// *content* a destination needs and is shared with the inbox router — an
  /// inbox entry has no identity to keep.
  final String captureId;

  final RoutedCapture capture;

  /// Chosen at launch time, not read off the project. Which agent should pick a
  /// task up is a property of the task, and the project's default is only the
  /// starting answer.
  final String agentId;

  /// The opening prompt. Kept to one line by construction — see
  /// [AgentHandoff.instructionFor] for why the capture's own text does not
  /// travel this way.
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

  /// The default opening prompt: a single line telling the agent which file to
  /// read.
  ///
  /// **The capture's text is deliberately not the prompt.** It would have to
  /// survive KDL escaping, an `--args` hand-off and the agent's own argument
  /// parsing, and a dictated note is exactly the input that breaks that chain —
  /// newlines, quotes, several kilobytes of it — while every layer fails by
  /// silently truncating rather than by refusing. A path is one short token, and
  /// putting the brief in the repository buys three things besides: it survives
  /// the session, every agent can read it without a code change here, and it is
  /// versioned with the project.
  String instructionFor(String captureId);

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
  String instructionFor(String captureId) => '';

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

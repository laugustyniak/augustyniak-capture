import '../../command/domain/command_client.dart';
import '../../projects/domain/project.dart';
import '../domain/capture_brief.dart';
import '../domain/capture_category.dart';
import '../domain/capture_router.dart';
import '../domain/route_record.dart';

/// Delivers a capture to the Command control plane: file the brief, then start
/// a planning session on the host the project is bound to.
///
/// The third destination behind `CaptureRouter`, and the first that leaves this
/// machine. It needs no new architecture — the seam was built for exactly this
/// — and it keeps every rule that seam already states.
///
/// **Delivery first, state second, and a throw leaves the capture open.** The
/// controller records nothing when `route` throws, so a failed hand-off leaves
/// the item on the desk and retryable. That is what makes the PUT's idempotency
/// on `capture_id` load-bearing rather than a nicety: the user *will* retry a
/// delivery that timed out, and the second attempt must update the brief the
/// collector already holds rather than file a second copy of one thought.
class CommandRouter implements CaptureRouter {
  const CommandRouter({
    required Project? Function(String projectId) projectById,
    required CommandClient client,
  }) : _projectById = projectById,
       _client = client;

  final Project? Function(String projectId) _projectById;
  final CommandClient _client;

  Project? _resolve(String? projectId) {
    if (projectId == null || projectId.isEmpty) return null;
    final Project? project = _projectById(projectId);
    if (project == null || !project.isBoundToCommand) return null;
    return project;
  }

  /// **Configuration, never the network.** The card gates its button on this
  /// inside `build`, and the seam's own docstring says destinations are
  /// configuration rather than state. So a bound project whose collector is
  /// down gets an enabled button and a failed delivery that leaves the capture
  /// on the desk — which is the correct shape, and the only one that does not
  /// require this app to poll a machine to decide whether to draw a control.
  @override
  bool canRoute(String? projectId) => _resolve(projectId) != null;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    final Project? project = _resolve(capture.projectId);
    if (project == null) throw const CaptureRoutingUnavailableException();

    final String host = project.commandHost!;
    final String workspace = project.commandWorkspace!;

    // The same serializer the local launcher writes with. One format, two
    // producers, and neither can drift from the other — which is the whole
    // reason the brief format shipped a slice before this one.
    final String content = renderCaptureBrief(
      captureId: capture.id,
      capture: capture,
      at: DateTime.now(),
      includeHeader: true,
      resultPath: '.agent-tasks/${capture.id}-result.md',
    );

    final CommandBrief brief = await _client.putBrief(
      host: host,
      workspace: workspace,
      captureId: capture.id,
      content: content,
    );

    final CommandSession session;
    try {
      session = await _client.startSession(
        host: host,
        workspace: workspace,
        briefId: brief.id,
      );
    } catch (exception) {
      // **The one failure that must not read like the other one.** The brief is
      // on the control plane and will still be there; what did not happen is
      // the session. Rethrowing the bare transport error would leave the user
      // unable to tell "the thought is lost" from "it is queued and nobody has
      // started on it", and those call for opposite next actions.
      throw CommandSessionNotStartedException(
        host: host,
        workspace: workspace,
        briefId: brief.id,
        cause: exception,
      );
    }

    return RouteRecord(
      // Stamped here rather than by the caller so the record cannot claim a
      // delivery time earlier than the exchange that produced it.
      at: DateTime.now(),
      kind: RouteKind.command,
      target: '$host · $workspace · ${session.name}',
    );
  }
}

/// The brief landed; no session started.
class CommandSessionNotStartedException implements Exception {
  const CommandSessionNotStartedException({
    required this.host,
    required this.workspace,
    required this.briefId,
    required this.cause,
  });

  final String host;
  final String workspace;
  final String briefId;
  final Object cause;

  @override
  String toString() =>
      'The brief reached $host · $workspace (id $briefId) but no session '
      'started, so nothing is working on it yet. Retrying is safe — the brief '
      'is keyed on this capture and will be updated rather than duplicated. '
      'Cause: $cause';
}

/// Chooses a destination per capture: the control plane for work an agent is
/// meant to execute, the project's own inbox for everything else.
///
/// **One decision point rather than a condition repeated per surface.** The
/// queue, the card and the controller all ask `canRoute` and call `route`, and
/// none of them should have to know that a bound project routes `agentTask`
/// somewhere different. Folding the choice in here keeps `CaptureRouter` the
/// single thing every caller talks to.
///
/// `canRoute` is the union: a capture can be routed if *either* destination
/// would take it. The category is not consulted there because it is consulted
/// in `route`, where the capture itself is in hand — and because a card whose
/// button appeared and disappeared as enrichment reclassified an item would be
/// a control that moves while being looked at.
class ProjectCaptureRouter implements CaptureRouter {
  const ProjectCaptureRouter({
    required CaptureRouter command,
    required CaptureRouter fallback,
    this.commandCategories = const <CaptureCategory>{CaptureCategory.agentTask},
  }) : _command = command,
       _fallback = fallback;

  final CaptureRouter _command;
  final CaptureRouter _fallback;

  /// What the control plane is for. Deliberately a set rather than a hard-coded
  /// `== agentTask`: `CaptureCategory` is a list of routing destinations, and
  /// the next one that belongs on a fleet should be a one-word change here.
  final Set<CaptureCategory> commandCategories;

  @override
  bool canRoute(String? projectId) =>
      _command.canRoute(projectId) || _fallback.canRoute(projectId);

  @override
  Future<RouteRecord> route(RoutedCapture capture) {
    final bool toCommand =
        capture.category != null &&
        commandCategories.contains(capture.category) &&
        _command.canRoute(capture.projectId);
    return toCommand ? _command.route(capture) : _fallback.route(capture);
  }
}

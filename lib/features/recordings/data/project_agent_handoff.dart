import 'dart:io';

import 'package:path/path.dart' as p;

import '../../projects/domain/agent_session_launcher.dart';
import '../../projects/domain/project.dart';
import '../domain/agent_handoff.dart';
import '../domain/capture_brief.dart';
import '../domain/capture_prompt.dart';
import '../domain/capture_router.dart';
import '../domain/route_record.dart';

/// Writes a capture into `.agent-tasks/<id>.md` in its project's repository,
/// then opens a coding agent session rooted there.
///
/// The directory is a sibling decision to `inbox.md`, for the same reasons: no
/// API, no token, no network, and the repository is already where this app puts
/// a project's durable text. The split is what each file is *for* — `inbox.md`
/// is a human reading list, while a brief here is an instruction addressed to a
/// process, and mixing the two would mean the agent had to be told which
/// section of a growing shared file was its job today.
///
/// **Append-only, like `inbox.md` and `revisions.jsonl`.** A second handoff of
/// the same capture adds a second brief rather than rewriting the file. That is
/// not tidiness: once an agent has been pointed at this path it may well have
/// written its own notes or results underneath, and rewriting the file from the
/// queue's memory is precisely the shape that once destroyed the recordings
/// index. Appending can lose at most the entry being written.
class ProjectAgentHandoff implements AgentHandoff {
  const ProjectAgentHandoff({
    required Project? Function(String projectId) projectById,
    required AgentSessionLauncher launcher,
    Directory? Function()? sessionsRoot,
    this.directoryName = '.agent-tasks',
  }) : _projectById = projectById,
       _launcher = launcher,
       _sessionsRoot = sessionsRoot;

  final Project? Function(String projectId) _projectById;
  final AgentSessionLauncher _launcher;

  /// Where a capture with no repository gets its own scratch folder, or null
  /// when there is none. A resolver, not a snapshot, like every swappable seam
  /// here: the answer is read at use, so an unconfigured install keeps the
  /// behaviour it had before scratch folders existed.
  final Directory? Function()? _sessionsRoot;
  final String directoryName;

  /// What this launcher will act on for [projectId], or null when it must not.
  ///
  /// **A bound project is refused here, and that is the demotion.** This
  /// launcher opens one CLI in one terminal on this machine and loses sight of
  /// it the moment it returns — no second prompt can reach the running session,
  /// and nothing ever reports back. Where a control plane is bound, all three
  /// of those are solved on the other side, and leaving both paths available
  /// would give one capture two ways out that differ only in whether anything
  /// will ever answer. So the offline case keeps the launcher, and the bound
  /// case does not see it: `agentsFor` answers empty and the queue hides the
  /// control rather than offering a worse one beside a better one.
  ///
  /// A capture with no usable repository — no project, a dangling id (a project
  /// deleted after the capture was filed, the same shape a dangling
  /// `activeProfileId` has in settings) or an empty `repoPath` — runs in a
  /// scratch folder instead, when [_sessionsRoot] provides one.
  ({Project? project, bool scratch})? _resolve(String? projectId) {
    final Project? project = projectId == null || projectId.isEmpty
        ? null
        : _projectById(projectId);
    if (project != null && project.isBoundToCommand) return null;
    if (project != null && project.repoPath.trim().isNotEmpty) {
      return (project: project, scratch: false);
    }
    if (_scratchRoot() == null) return null;
    return (project: project, scratch: true);
  }

  Directory? _scratchRoot() => _sessionsRoot?.call();

  @override
  String? workspacePathFor(String captureId, String? projectId) {
    final ({Project? project, bool scratch})? target = _resolve(projectId);
    if (target == null || !target.scratch) return null;
    return p.join(_scratchRoot()!.path, captureId);
  }

  @override
  List<HandoffAgent> agentsFor(String? projectId) {
    final ({Project? project, bool scratch})? target = _resolve(projectId);
    if (target == null) return const <HandoffAgent>[];
    return <HandoffAgent>[
      for (final AgentKind agent in AgentKind.values)
        HandoffAgent(
          id: agent.name,
          label: agentLabel(agent),
          isDefault: target.project?.defaultAgent == agent,
        ),
    ];
  }

  /// Always `/`-separated: this string is rendered into a prompt and into
  /// markdown, never resolved by `dart:io`. [_taskFile] builds the real path.
  @override
  String taskPathFor(String captureId) => '$directoryName/$captureId.md';

  /// The capture's own words, and nothing wrapped around them — the rules and
  /// the reasoning live in [capturePrompt], which a projectless capture uses
  /// too.
  @override
  String promptFor(RoutedCapture capture) => capturePrompt(capture);

  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async {
    final ({Project? project, bool scratch})? target = _resolve(
      request.capture.projectId,
    );
    if (target == null) throw const AgentHandoffUnavailableException();
    final Project? project = target.project;
    final String? workspace = workspacePathFor(
      request.captureId,
      request.capture.projectId,
    );
    final String repoPath = workspace ?? project!.repoPath;

    final AgentKind? agent = AgentKind.fromName(request.agentId);
    if (agent == null) {
      throw AgentHandoffFailure('Unknown agent: ${request.agentId}');
    }

    // A scratch folder is ours to create, on first send, and never to delete:
    // the agent's results live in it after the session is gone.
    if (workspace != null) await Directory(workspace).create(recursive: true);
    final Directory repo = Directory(repoPath);
    if (!await repo.exists()) {
      // Named rather than swallowed: a moved checkout and a silent agent look
      // identical from the queue, and only one of them is the user's problem.
      throw FileSystemException(
        'Project repository not found',
        repoPath,
      );
    }

    // The brief goes down first. An agent started against a file that is not
    // there yet reads nothing and reports nothing — the one failure the user
    // could not diagnose from either end.
    final File file = _taskFile(repoPath, request.captureId);
    final bool existed = await file.exists();
    if (!existed) await file.parent.create(recursive: true);
    await file.writeAsString(
      _render(request, first: !existed),
      mode: FileMode.writeOnlyAppend,
    );

    final ProjectAgent launcherAgent = _launcherAgent(agent);
    final AgentSettings settings =
        project?.settingsFor(agent) ?? const AgentSettings();
    final AgentSessionLaunchResult session = await _launcher.launch(
      AgentSessionLaunchRequest(
        projectId: project?.id ?? 'capture-${request.captureId}',
        projectName: project?.name ?? 'Capture',
        repoPath: repoPath,
        agent: launcherAgent,
        // Explicit for a scratch run: the launcher derives a name from the
        // project id's first eight characters, and `capture-` is all of them,
        // so two projectless captures would attach to each other's session.
        sessionName: workspace == null
            ? project!.sessionName
            : _scratchSessionName(request.captureId),
        arguments: <String>[
          ...settings.additionalArgs,
          if (settings.skipPermissions) ...launcherAgent.skipPermissionsArguments,
          // The project's own `initialPrompt` is deliberately not appended. It
          // is the opening line for a session started *from the project card*,
          // with no particular task in hand; here there is a task, and two
          // prompts would leave the agent to guess which one it was started for.
          ...launcherAgent.promptArguments(request.instruction),
        ],
      ),
    );

    return AgentHandoffResult(
      record: RouteRecord(
        // Stamped after the launch so the record cannot claim a delivery time
        // earlier than the session that produced it.
        at: DateTime.now(),
        kind: RouteKind.agent,
        target: '${agentLabel(agent)} · ${session.sessionName}',
      ),
      taskPath: taskPathFor(request.captureId),
      sessionName: session.sessionName,
      attachedToExistingSession: session.attachedToExistingSession,
    );
  }

  File _taskFile(String repoPath, String captureId) =>
      File(p.join(repoPath, directoryName, '$captureId.md'));

  /// `capture-` plus the first twelve alphanumerics of the id: lowercase and
  /// dash-only so Zellij accepts it, short enough that the launcher's 63
  /// character bound never truncates the part that tells captures apart.
  static String _scratchSessionName(String captureId) {
    final String id = captureId.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    return 'capture-${id.length > 12 ? id.substring(0, 12) : id}';
  }

  /// Delegates to [renderCaptureBrief], which is now the single definition of
  /// this format — see there for why it exists before there is a second writer.
  ///
  /// The italic facts line the old renderer printed under each `## Handoff` is
  /// gone: capture time, category and tags are in the front matter now, where a
  /// reader can parse them, and repeating them as decoration would leave two
  /// copies of one fact to disagree.
  String _render(AgentHandoffRequest request, {required bool first}) =>
      renderCaptureBrief(
        captureId: request.captureId,
        capture: request.capture,
        at: DateTime.now(),
        includeHeader: first,
        resultPath: '$directoryName/${request.captureId}-result.md',
      );

  static String agentLabel(AgentKind agent) => switch (agent) {
    AgentKind.codex => 'Codex',
    AgentKind.claudeCode => 'Claude Code',
    AgentKind.antigravity => 'Antigravity',
    AgentKind.geminiCli => 'Gemini CLI',
  };

  static ProjectAgent _launcherAgent(AgentKind agent) => switch (agent) {
    AgentKind.codex => ProjectAgent.codex,
    AgentKind.claudeCode => ProjectAgent.claude,
    AgentKind.antigravity => ProjectAgent.antigravity,
    AgentKind.geminiCli => ProjectAgent.gemini,
  };
}

class AgentHandoffFailure implements Exception {
  const AgentHandoffFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../projects/domain/agent_session_launcher.dart';
import '../../projects/domain/project.dart';
import '../domain/agent_handoff.dart';
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
    this.directoryName = '.agent-tasks',
  }) : _projectById = projectById,
       _launcher = launcher;

  final Project? Function(String projectId) _projectById;
  final AgentSessionLauncher _launcher;
  final String directoryName;

  Project? _resolve(String? projectId) {
    if (projectId == null || projectId.isEmpty) return null;
    // A project deleted after the capture was filed leaves a dangling id on the
    // item, the same shape a dangling `activeProfileId` has in settings.
    final Project? project = _projectById(projectId);
    if (project == null) return null;
    return project.repoPath.trim().isEmpty ? null : project;
  }

  @override
  List<HandoffAgent> agentsFor(String? projectId) {
    final Project? project = _resolve(projectId);
    if (project == null) return const <HandoffAgent>[];
    return <HandoffAgent>[
      for (final AgentKind agent in AgentKind.values)
        HandoffAgent(
          id: agent.name,
          label: agentLabel(agent),
          isDefault: project.defaultAgent == agent,
        ),
    ];
  }

  /// Always `/`-separated: this string is rendered into a prompt and into
  /// markdown, never resolved by `dart:io`. [_taskFile] builds the real path.
  @override
  String taskPathFor(String captureId) => '$directoryName/$captureId.md';

  @override
  String instructionFor(String captureId) =>
      'Read ${taskPathFor(captureId)} and start on the task described there.';

  @override
  Future<AgentHandoffResult> handoff(AgentHandoffRequest request) async {
    final Project? project = _resolve(request.capture.projectId);
    if (project == null) throw const AgentHandoffUnavailableException();

    final AgentKind? agent = AgentKind.fromName(request.agentId);
    if (agent == null) {
      throw AgentHandoffFailure('Unknown agent: ${request.agentId}');
    }

    final Directory repo = Directory(project.repoPath);
    if (!await repo.exists()) {
      // Named rather than swallowed: a moved checkout and a silent agent look
      // identical from the queue, and only one of them is the user's problem.
      throw FileSystemException(
        'Project repository not found',
        project.repoPath,
      );
    }

    // The brief goes down first. An agent started against a file that is not
    // there yet reads nothing and reports nothing — the one failure the user
    // could not diagnose from either end.
    final File file = _taskFile(project, request.captureId);
    final bool existed = await file.exists();
    if (!existed) await file.parent.create(recursive: true);
    await file.writeAsString(
      _render(request, first: !existed),
      mode: FileMode.writeOnlyAppend,
    );

    final ProjectAgent target = _launcherAgent(agent);
    final AgentSettings settings = project.settingsFor(agent);
    final AgentSessionLaunchResult session = await _launcher.launch(
      AgentSessionLaunchRequest(
        projectId: project.id,
        projectName: project.name,
        repoPath: project.repoPath,
        agent: target,
        sessionName: project.sessionName,
        arguments: <String>[
          ...settings.additionalArgs,
          // The project's own `initialPrompt` is deliberately not appended. It
          // is the opening line for a session started *from the project card*,
          // with no particular task in hand; here there is a task, and two
          // prompts would leave the agent to guess which one it was started for.
          ...target.promptArguments(request.instruction),
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

  File _taskFile(Project project, String captureId) =>
      File(p.join(project.repoPath, directoryName, '$captureId.md'));

  String _render(AgentHandoffRequest request, {required bool first}) {
    final RoutedCapture capture = request.capture;
    final StringBuffer buffer = StringBuffer();
    if (first) {
      buffer
        ..writeln('# ${capture.title}')
        ..writeln();
    }
    buffer
      ..writeln('## Handoff ${DateTime.now().toIso8601String()}')
      ..writeln();

    final List<String> facts = <String>[
      'captured ${capture.capturedAt.toIso8601String()}',
      if (capture.category != null) capture.category!.name,
      ...capture.tags.map((String tag) => '#$tag'),
    ];
    buffer
      ..writeln('*${facts.join(' · ')}*')
      ..writeln();

    final String summary = capture.summary?.trim() ?? '';
    if (summary.isNotEmpty) {
      buffer
        ..writeln('> $summary')
        ..writeln();
    }

    final String body = capture.body.trim();
    if (body.isNotEmpty) {
      buffer
        ..writeln(body)
        ..writeln();
    }
    return buffer.toString();
  }

  static String agentLabel(AgentKind agent) => switch (agent) {
    AgentKind.codex => 'Codex',
    AgentKind.claudeCode => 'Claude Code',
    AgentKind.antigravity => 'Antigravity',
  };

  static ProjectAgent _launcherAgent(AgentKind agent) => switch (agent) {
    AgentKind.codex => ProjectAgent.codex,
    AgentKind.claudeCode => ProjectAgent.claude,
    AgentKind.antigravity => ProjectAgent.antigravity,
  };
}

class AgentHandoffFailure implements Exception {
  const AgentHandoffFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

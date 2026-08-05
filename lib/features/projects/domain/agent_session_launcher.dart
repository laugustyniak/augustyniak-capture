/// Agent CLIs that Augustyniak Capture may start inside a project session.
enum ProjectAgent {
  codex('codex'),
  claude('claude'),
  antigravity('agy');

  const ProjectAgent(this.executable);

  /// Controlled executable name. Callers cannot provide an arbitrary command.
  final String executable;
}

/// The complete, structured input needed to launch an agent.
///
/// [arguments] are passed directly to the selected executable. They are never
/// interpolated into a shell command.
class AgentSessionLaunchRequest {
  const AgentSessionLaunchRequest({
    required this.projectId,
    required this.projectName,
    required this.repoPath,
    required this.agent,
    this.sessionName,
    this.arguments = const <String>[],
  });

  final String projectId;
  final String projectName;
  final String repoPath;
  final ProjectAgent agent;

  /// Optional stable base configured by the project. The agent is appended.
  final String? sessionName;
  final List<String> arguments;
}

class AgentSessionLaunchResult {
  const AgentSessionLaunchResult({
    required this.sessionName,
    required this.attachedToExistingSession,
  });

  final String sessionName;
  final bool attachedToExistingSession;
}

/// Starts (or reattaches to) an agent only when [launch] is explicitly called.
abstract interface class AgentSessionLauncher {
  Future<AgentSessionLaunchResult> launch(AgentSessionLaunchRequest request);
}

class AgentSessionLaunchException implements Exception {
  const AgentSessionLaunchException(this.message);

  final String message;

  @override
  String toString() => 'AgentSessionLaunchException: $message';
}

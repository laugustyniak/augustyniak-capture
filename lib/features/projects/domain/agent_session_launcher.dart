/// Agent CLIs that Augustyniak Capture may start inside a project session.
enum ProjectAgent {
  codex('codex'),
  claude('claude'),
  antigravity('agy');

  const ProjectAgent(this.executable);

  /// Controlled executable name. Callers cannot provide an arbitrary command.
  final String executable;

  /// How this CLI wants an opening prompt passed to it.
  ///
  /// One definition on the enum rather than a `switch` at each call site: there
  /// are two callers now (a project's configured prompt and a capture handoff)
  /// and a third would silently start every Antigravity session with its prompt
  /// read as a positional argument — which that CLI does not treat as a prompt
  /// at all, so the session would open with no task and no error.
  List<String> promptArguments(String prompt) {
    final String safe = disarmOptionLookalike(prompt);
    return switch (this) {
      ProjectAgent.antigravity => <String>['--prompt-interactive', safe],
      ProjectAgent.codex || ProjectAgent.claude => <String>[safe],
    };
  }

  /// A prompt that would otherwise be read as an option, made positional.
  ///
  /// The prompt *is* the capture's own text — a dictated note, or OCR off an
  /// image somebody else made — and it arrives here as an argv element that
  /// every CLI argument parser inspects before it looks for positionals. A
  /// capture opening with `--dangerously-skip-permissions` therefore does not
  /// reach the agent as a task; it reaches it as a flag, and the one flag worth
  /// smuggling is the one that turns tool approval off.
  ///
  /// A leading space rather than a `--` separator, deliberately: `--` has to be
  /// supported by the parser on the other side, and this app cannot verify what
  /// three third-party CLIs do with it. A value that does not start with `-` is
  /// a positional to every parser there is, and a space is invisible to the
  /// model that reads the prompt.
  static String disarmOptionLookalike(String prompt) =>
      prompt.startsWith('-') ? ' $prompt' : prompt;
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

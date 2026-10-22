import 'native_agent_types.dart';

/// Agent CLIs that Augustyniak Capture may start inside a project session.
enum ProjectAgent {
  codex('codex'),
  claude('claude'),
  antigravity('agy'),
  gemini('gemini');

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
      ProjectAgent.gemini => <String>['-i', safe],
      ProjectAgent.codex || ProjectAgent.claude => <String>[safe],
    };
  }

  /// This CLI's spelling of "skip permission prompts".
  ///
  /// Codex rejects the spelling the other two share, so handing it the wrong
  /// one opens a terminal on an agent that has already exited.
  List<String> get skipPermissionsArguments => switch (this) {
    ProjectAgent.codex => const <String>[
      '--dangerously-bypass-approvals-and-sandbox',
    ],
    ProjectAgent.claude || ProjectAgent.antigravity => const <String>[
      '--dangerously-skip-permissions',
    ],
    ProjectAgent.gemini => const <String>['--yolo'],
  };

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
    this.prompt,
    this.detached = false,
  });

  final String projectId;
  final String projectName;
  final String repoPath;
  final ProjectAgent agent;

  /// Optional stable base configured by the project. The agent is appended.
  final String? sessionName;
  final List<String> arguments;

  /// Text sent through stdin by a native background adapter.
  ///
  /// Null keeps old callers source-compatible. The Zellij launcher adds this
  /// to its own positional prompt arguments, while a native launcher keeps it
  /// out of the process list entirely.
  final String? prompt;

  /// Start the session in the background, with no terminal window.
  ///
  /// The agent runs inside the multiplexer's server from the first moment, and
  /// the user joins it later — through [AgentSessionLauncher.attach], or from
  /// any terminal already open with [attachCommandFor]. A launch that needs no
  /// window also needs no terminal, which is what makes it work on a host
  /// whose terminal cannot open one (#291) and what keeps a capture from
  /// stealing the screen every time it is handed off.
  final bool detached;
}

class AgentSessionLaunchResult {
  const AgentSessionLaunchResult({
    required this.sessionName,
    required this.attachedToExistingSession,
    this.detached = false,
    this.job,
  });

  final String sessionName;
  final bool attachedToExistingSession;

  /// No window was opened: the session is running in the background and the
  /// user has to attach to see it.
  final bool detached;

  /// Native background job, absent for every legacy Zellij/window launch.
  final NativeAgentJobHandle? job;
}

/// What to type in any terminal to join [sessionName].
///
/// One definition, shared by the sheet's copy button, the card and the logs,
/// so the command the user is shown is the one the launcher would run.
String attachCommandFor(String sessionName) => 'zellij attach $sessionName';

/// Starts (or reattaches to) an agent only when [launch] is explicitly called.
abstract interface class AgentSessionLauncher {
  Future<AgentSessionLaunchResult> launch(AgentSessionLaunchRequest request);

  /// Opens a terminal window attached to the running session [sessionName].
  ///
  /// Throws [AgentSessionLaunchException] when the session is not running —
  /// by name, so the message says which one — or when no terminal can open.
  /// Nothing is started and nothing is written: a session that has ended is
  /// gone, and restarting it is a new launch with a new prompt.
  Future<void> attach(String sessionName);
}

class AgentSessionLaunchException implements Exception {
  const AgentSessionLaunchException(this.message);

  final String message;

  @override
  String toString() => 'AgentSessionLaunchException: $message';
}

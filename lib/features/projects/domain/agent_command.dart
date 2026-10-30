import 'agent_session_launcher.dart';

/// A configured agent invocation: an executable and its leading arguments.
///
/// Built only by [parseAgentCommand] from text the user typed into Config.
/// It is never built from a capture, and a model's output never reaches it.
class AgentCommand {
  const AgentCommand({
    required this.agent,
    required this.executable,
    required this.arguments,
  });

  /// Which CLI this is. It decides the native background backend (the flags
  /// and the output parser), so an unknown program cannot be launched: it
  /// would never emit the event that confirms the prompt.
  final ProjectAgent agent;

  /// The first word as typed: a bare name (resolved through
  /// `ExecutableResolver`) or an absolute path.
  final String executable;
  final List<String> arguments;
}

class AgentCommandParse {
  const AgentCommandParse({this.command, this.problem});

  /// Null when the text was blank or invalid.
  final AgentCommand? command;

  /// Why the text was refused, for the Config tab. Null for blank text.
  final String? problem;
}

/// Splits [input] into an argv, **without a shell**: whitespace separates
/// words, single and double quotes group them, and nothing is expanded except
/// a leading `~/` (also after `=`), because a shell is not there to do it and
/// the natural example `--mcp-config ~/.claude/todoist.json` would otherwise
/// reach the CLI as a literal tilde.
///
/// The first word's basename must be `claude`, `codex` or `agy`, and no word
/// may be a permission-bypass flag: this field must not become the way to
/// start an agent with its approvals off.
AgentCommandParse parseAgentCommand(String input, {String? home}) {
  if (input.trim().isEmpty) return const AgentCommandParse();
  if (input.contains('\u0000')) {
    return const AgentCommandParse(problem: 'The command contains a NUL.');
  }
  final List<String>? words = _split(input);
  if (words == null) {
    return const AgentCommandParse(problem: 'A quote is not closed.');
  }
  if (words.isEmpty) return const AgentCommandParse();
  final String first = words.first;
  final String name = first
      .split(RegExp(r'[/\\]'))
      .last
      .toLowerCase()
      .replaceFirst(RegExp(r'\.exe$'), '');
  final ProjectAgent? agent = switch (name) {
    'claude' => ProjectAgent.claude,
    'codex' => ProjectAgent.codex,
    'agy' => ProjectAgent.antigravity,
    _ => null,
  };
  if (agent == null) {
    return const AgentCommandParse(
      problem:
          'The command must start with claude, codex or agy — only those run '
          'in the background (macOS and Linux). Put wrappers behind one of '
          'them.',
    );
  }
  final bool isPath = first.contains('/') || first.contains(r'\');
  if (isPath && !_isAbsolute(_expandTilde(first, home))) {
    return const AgentCommandParse(
      problem:
          'Use a bare program name or an absolute path; a relative path '
          'depends on where the app was started.',
    );
  }
  final List<String> rest = <String>[
    for (final String word in words.skip(1)) _expandTilde(word, home),
  ];
  final String? problem = _checkAllowlist(agent, rest);
  if (problem != null) return AgentCommandParse(problem: problem);
  return AgentCommandParse(
    command: AgentCommand(
      agent: agent,
      executable: _expandTilde(first, home),
      arguments: rest,
    ),
  );
}

bool _isAbsolute(String path) =>
    path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// **An allowlist, not a denylist.** Every CLI has more ways to widen its own
/// permissions than any list of bad flags can name (profiles, settings files,
/// trust levels, allowed-tool lists, approval modes), so after the program only
/// a short list of flags is accepted and everything else is refused with the
/// reason shown in Config. A value is one word that does not start with `-`;
/// both `--flag value` and `--flag=value` are read. A stray word is refused:
/// it would be a prompt.
///
/// - `claude`: `--mcp-config <path>`, `--model <name>`, `--strict-mcp-config`.
///   The config file is the user's own choice, and what it contains is as
///   trusted as the user's other Claude configuration.
/// - `codex`: `--model <name>` only. `-c`/`--config` is not accepted: a
///   `mcp_servers.*` entry can start any program, so no key of it is safe to
///   allow.
/// - `agy`: nothing.
String? _checkAllowlist(ProjectAgent agent, List<String> args) {
  final String allowed = switch (agent) {
    ProjectAgent.claude =>
      'Allowed after claude: --mcp-config <path>, --model <name>, '
          '--strict-mcp-config.',
    ProjectAgent.codex => 'Allowed after codex: --model <name> only.',
    _ => 'Nothing is allowed after agy.',
  };
  String refuse(String word, String why) =>
      '$word is $why. $allowed Approval, sandbox, profile and settings '
      'controls are never accepted.';
  for (int i = 0; i < args.length; i++) {
    final String word = args[i];
    final int eq = word.startsWith('--') ? word.indexOf('=') : -1;
    final String name = eq > 0 ? word.substring(0, eq) : word;
    final String? inline = eq > 0 ? word.substring(eq + 1) : null;
    final bool takesValue = switch (agent) {
      ProjectAgent.claude => name == '--mcp-config' || name == '--model',
      ProjectAgent.codex => name == '--model',
      _ => false,
    };
    final bool flag =
        agent == ProjectAgent.claude && name == '--strict-mcp-config';
    if (flag) {
      if (inline != null) return refuse(word, 'a switch and takes no value');
      continue;
    }
    if (!takesValue) return refuse(word, 'not an accepted option');
    final String? value = inline ?? (i + 1 < args.length ? args[++i] : null);
    if (value == null || value.isEmpty || value.startsWith('-')) {
      return refuse(word, 'missing its value');
    }
  }
  return null;
}

/// Whether [arguments] contain something known to widen what an agent may do:
/// approvals, the sandbox, profiles, trusted settings, extra directories or
/// tools. A **best-effort denylist**, not a proof: it is used for display (the
/// Jobs list's APPROVALS OFF pill) and as a guard on the unattended SMART path
/// over a project's own arguments, which are the user's configuration. The
/// Todoist command does not rely on it — that field is an allowlist. [agent]
/// only exempts `-p` for claude, where it means `--print`; for codex and any
/// unknown agent it is read as `--profile`.
bool argumentsControlApprovals(List<String> arguments, {ProjectAgent? agent}) =>
    approvalControlIn(arguments, agent: agent) != null;

/// The first offending argument, or null.
String? approvalControlIn(List<String> arguments, {ProjectAgent? agent}) {
  for (int i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    final String lower = argument.split('=').first.toLowerCase();
    if (lower.startsWith('--dangerously') ||
        lower.startsWith('--allow-dangerously') ||
        lower.startsWith('--approval') ||
        lower.startsWith('--permission') ||
        lower.startsWith('--sandbox') ||
        lower.startsWith('--auto') ||
        lower == '--ask-for-approval' ||
        lower == '--yolo' ||
        lower == '--yes' ||
        lower == '--full-auto' ||
        lower == '--profile' ||
        lower == '--settings' ||
        lower == '--setting-sources' ||
        lower == '--allowedtools' ||
        lower == '--allowed-tools' ||
        lower == '--add-dir' ||
        lower == '--cd' ||
        lower == '--tools' ||
        lower == '--plugin-dir') {
      return argument;
    }
    // Short options, with the value attached or not: `-s x`, `-sx`, `-a never`.
    if (RegExp(r'^-[sayC]').hasMatch(argument)) return argument;
    if (agent != ProjectAgent.claude && RegExp(r'^-p').hasMatch(argument)) {
      return argument;
    }
    final String? configValue = argument == '-c' || argument == '--config'
        ? (i + 1 < arguments.length ? arguments[i + 1] : '')
        : argument.startsWith('--config=')
        ? argument.substring('--config='.length)
        : RegExp(r'^-c.').hasMatch(argument)
        ? argument.substring(2)
        : null;
    if (configValue != null &&
        RegExp(
          r'approval|sandbox|profile|trust|^projects\.|shell_environment_policy|'
          r'default_permissions|^features\.',
          caseSensitive: false,
        ).hasMatch(configValue)) {
      return argument;
    }
  }
  return null;
}

String _expandTilde(String word, String? home) {
  if (home == null || home.isEmpty) return word;
  if (word == '~') return home;
  if (word.startsWith('~/')) return '$home${word.substring(1)}';
  final int eq = word.indexOf('=~/');
  if (word.startsWith('-') && eq > 0) {
    return '${word.substring(0, eq + 1)}$home${word.substring(eq + 2)}';
  }
  return word;
}

/// Null for an unclosed quote.
List<String>? _split(String input) {
  final List<String> words = <String>[];
  final StringBuffer current = StringBuffer();
  bool inWord = false;
  String? quote;
  for (int i = 0; i < input.length; i++) {
    final String c = input[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (quote == '"' &&
          c == r'\' &&
          i + 1 < input.length &&
          (input[i + 1] == '"' || input[i + 1] == r'\')) {
        current.write(input[++i]);
      } else {
        current.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      inWord = true;
    } else if (c.trim().isEmpty) {
      if (inWord) words.add(current.toString());
      current.clear();
      inWord = false;
    } else {
      current.write(c);
      inWord = true;
    }
  }
  if (quote != null) return null;
  if (inWord) words.add(current.toString());
  return words;
}

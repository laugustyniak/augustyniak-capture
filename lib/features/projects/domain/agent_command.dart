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
  final String name = first.split('/').last;
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
          'in the background. Put wrappers behind one of them.',
    );
  }
  final List<String> rest = <String>[
    for (final String word in words.skip(1)) _expandTilde(word, home),
  ];
  for (final String word in rest) {
    if (_bypassFlags.contains(word.split('=').first) ||
        word.startsWith('--dangerously')) {
      return AgentCommandParse(
        problem: '$word turns tool approvals off and is not allowed here.',
      );
    }
  }
  return AgentCommandParse(
    command: AgentCommand(
      agent: agent,
      executable: _expandTilde(first, home),
      arguments: rest,
    ),
  );
}

final Set<String> _bypassFlags = <String>{
  for (final ProjectAgent agent in ProjectAgent.values)
    ...agent.skipPermissionsArguments,
  '--yolo',
};

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

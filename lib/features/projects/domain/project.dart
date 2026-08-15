/// A coding agent that can be started in a project's repository.
enum AgentKind {
  codex,
  claudeCode,
  antigravity;

  /// Returns null for values written by a newer app version.
  ///
  /// Unknown agents must not make the rest of a project unreadable. The
  /// launcher can simply omit an action it does not understand yet.
  static AgentKind? fromName(String? name) {
    if (name == 'claude') return AgentKind.claudeCode;
    if (name == 'gemini') return AgentKind.antigravity;
    return AgentKind.values.asNameMap()[name];
  }
}

/// Per-agent launch options owned by a [Project].
///
/// Arguments are modelled as separate values rather than a shell command. A
/// launcher can therefore pass them directly to a process without shell
/// interpolation or quoting ambiguity.
class AgentSettings {
  const AgentSettings({
    this.additionalArgs = const <String>[],
    this.initialPrompt,
  });

  final List<String> additionalArgs;
  final String? initialPrompt;

  bool get isEmpty => additionalArgs.isEmpty && initialPrompt == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'additionalArgs': additionalArgs,
    'initialPrompt': initialPrompt,
  };

  factory AgentSettings.fromJson(Map<String, dynamic> json) {
    // `args` is accepted as an early/legacy spelling. Values are filtered so a
    // stray hand-edited number does not discard otherwise valid settings.
    final dynamic rawArgs = json['additionalArgs'] ?? json['args'];
    return AgentSettings(
      additionalArgs: rawArgs is List<dynamic>
          ? rawArgs.whereType<String>().toList(growable: false)
          : const <String>[],
      initialPrompt: json['initialPrompt'] is String
          ? json['initialPrompt'] as String
          : null,
    );
  }
}

/// An executable work context associated with captured content.
///
/// A project is deliberately distinct from a tag: tags classify content,
/// while this object owns the repository and agent-launch context.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.repoPath,
    this.description,
    this.sessionName,
    this.defaultAgent,
    this.agentSettings = const <AgentKind, AgentSettings>{},
    this.commandHost,
    this.commandWorkspace,
    this.commandBoundAt,
  });

  final String id;
  final String name;
  final String repoPath;
  final String? description;
  final String? sessionName;
  final AgentKind? defaultAgent;
  final Map<AgentKind, AgentSettings> agentSettings;

  /// Where this project's work goes on the Command control plane.
  ///
  /// `repoPath` says where the checkout is on *this* machine; these say which
  /// `(host, workspace)` owns the work on the fleet. Left implicit the two
  /// drift apart the first time a repository moves, which is the failure this
  /// binding exists to prevent — so the pair is stored rather than derived from
  /// a path, and it is filled from two pickers over live reads rather than
  /// typed, because a typed workspace is a third source of truth with no
  /// validation.
  ///
  /// All three are absent on every project written before this existed, and on
  /// every project the user never binds. [isBoundToCommand] is the one question
  /// worth asking of them.
  final String? commandHost;
  final String? commandWorkspace;

  /// When the binding was made, so a stale one can be recognised as stale
  /// rather than merely wrong. Absent while unbound.
  final DateTime? commandBoundAt;

  /// A capture from this project can be addressed on the control plane.
  ///
  /// Both halves or neither: a host with no workspace addresses nothing, and a
  /// workspace with no host cannot be reached at all. Answering true for half a
  /// binding would put an enabled control in front of a request that cannot be
  /// built.
  bool get isBoundToCommand =>
      (commandHost?.trim().isNotEmpty ?? false) &&
      (commandWorkspace?.trim().isNotEmpty ?? false);

  AgentSettings settingsFor(AgentKind agent) =>
      agentSettings[agent] ?? const AgentSettings();

  Project copyWith({
    String? name,
    String? repoPath,
    String? description,
    bool clearDescription = false,
    String? sessionName,
    bool clearSessionName = false,
    AgentKind? defaultAgent,
    bool clearDefaultAgent = false,
    Map<AgentKind, AgentSettings>? agentSettings,
    String? commandHost,
    String? commandWorkspace,
    DateTime? commandBoundAt,
    bool clearCommandBinding = false,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      repoPath: repoPath ?? this.repoPath,
      description: clearDescription ? null : (description ?? this.description),
      sessionName: clearSessionName ? null : (sessionName ?? this.sessionName),
      defaultAgent: clearDefaultAgent
          ? null
          : (defaultAgent ?? this.defaultAgent),
      agentSettings: agentSettings ?? this.agentSettings,
      // One flag clears all three, because half a binding is not a state this
      // type admits — see [isBoundToCommand].
      commandHost: clearCommandBinding ? null : (commandHost ?? this.commandHost),
      commandWorkspace: clearCommandBinding
          ? null
          : (commandWorkspace ?? this.commandWorkspace),
      commandBoundAt: clearCommandBinding
          ? null
          : (commandBoundAt ?? this.commandBoundAt),
    );
  }

  /// The three Command keys are **omitted when absent**, unlike every field
  /// above them.
  ///
  /// The surrounding style writes `description: null` and always has, so
  /// changing that would rewrite every row in `projects.json` on the next save.
  /// Omitting instead means a project nobody binds serialises byte for byte as
  /// it did before this feature existed — which is the only way to tell "this
  /// build added nothing" from "this build quietly touched every project".
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'repoPath': repoPath,
    'description': description,
    'sessionName': sessionName,
    'defaultAgent': defaultAgent?.name,
    'agentSettings': <String, dynamic>{
      for (final MapEntry<AgentKind, AgentSettings> entry
          in agentSettings.entries)
        entry.key.name: entry.value.toJson(),
    },
    if (commandHost != null) 'commandHost': commandHost,
    if (commandWorkspace != null) 'commandWorkspace': commandWorkspace,
    if (commandBoundAt != null)
      'commandBoundAt': commandBoundAt!.toIso8601String(),
  };

  factory Project.fromJson(Map<String, dynamic> json) {
    final dynamic rawId = json['id'];
    if (rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('Project id must be a non-empty string');
    }

    final Map<AgentKind, AgentSettings> settings = <AgentKind, AgentSettings>{};
    final dynamic rawSettings = json['agentSettings'];
    if (rawSettings is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in rawSettings.entries) {
        final AgentKind? kind = AgentKind.fromName(entry.key);
        final dynamic value = entry.value;
        if (kind != null && value is Map<String, dynamic>) {
          settings[kind] = AgentSettings.fromJson(value);
        }
      }
    }

    return Project(
      id: rawId,
      name: json['name'] is String ? json['name'] as String : 'Project',
      repoPath: json['repoPath'] is String ? json['repoPath'] as String : '',
      description: json['description'] is String
          ? json['description'] as String
          : null,
      sessionName: json['sessionName'] is String
          ? json['sessionName'] as String
          : null,
      defaultAgent: AgentKind.fromName(
        json['defaultAgent'] is String ? json['defaultAgent'] as String : null,
      ),
      agentSettings: settings,
      commandHost: _text(json['commandHost']),
      commandWorkspace: _text(json['commandWorkspace']),
      // A hand-edited or newer-build timestamp that will not parse costs the
      // binding's *age*, never the binding — the same degrade every other
      // optional field here makes, and the pair is what addresses the work.
      commandBoundAt: DateTime.tryParse(_text(json['commandBoundAt']) ?? ''),
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

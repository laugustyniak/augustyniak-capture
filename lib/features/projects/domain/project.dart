/// A coding agent that can be started in a project's repository.
enum AgentKind {
  codex,
  claudeCode,
  gemini;

  /// Returns null for values written by a newer app version.
  ///
  /// Unknown agents must not make the rest of a project unreadable. The
  /// launcher can simply omit an action it does not understand yet.
  static AgentKind? fromName(String? name) {
    if (name == 'claude') return AgentKind.claudeCode;
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
  });

  final String id;
  final String name;
  final String repoPath;
  final String? description;
  final String? sessionName;
  final AgentKind? defaultAgent;
  final Map<AgentKind, AgentSettings> agentSettings;

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
    );
  }

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
    );
  }
}

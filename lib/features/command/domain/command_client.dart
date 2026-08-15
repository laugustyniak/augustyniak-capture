/// One machine the Command control plane can start work on.
///
/// [id] is what every later call addresses — the path segment in
/// `/api/{host}/workspaces/…` — while [label] is only ever shown. They are
/// separate because a fleet names a host for people (`studio (macOS, idle)`)
/// and addresses it as a slug, and binding a project to the *shown* form is the
/// class of drift this whole feature exists to prevent.
class CommandHost {
  const CommandHost({required this.id, required this.label});

  final String id;
  final String label;

  /// Null for a row this build cannot read, which is then dropped.
  ///
  /// A host with no id cannot be addressed, so keeping it would put an entry in
  /// the picker that fails at the moment of binding rather than at the moment
  /// of listing — the later and more expensive of the two.
  static CommandHost? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? id = json['id'] ?? json['name'] ?? json['host'];
    if (id is! String || id.trim().isEmpty) return null;
    final Object? label = json['label'] ?? json['display_name'];
    return CommandHost(
      id: id.trim(),
      label: label is String && label.trim().isNotEmpty ? label.trim() : id.trim(),
    );
  }
}

/// One checkout on a host, as the control plane knows it.
///
/// [path] is carried only so the picker can tell two workspaces with the same
/// name apart; nothing in this app resolves it. `repoPath` stays authoritative
/// for `inbox.md` and the local launcher, and for nothing else.
class CommandWorkspace {
  const CommandWorkspace({required this.name, this.path});

  final String name;
  final String? path;

  static CommandWorkspace? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? name = json['name'] ?? json['workspace'];
    if (name is! String || name.trim().isEmpty) return null;
    final Object? path = json['path'];
    return CommandWorkspace(
      name: name.trim(),
      path: path is String && path.trim().isNotEmpty ? path.trim() : null,
    );
  }
}

/// One brief the control plane is holding, as it answered.
class CommandBrief {
  const CommandBrief({required this.id, this.path});

  final String id;

  /// Where the collector put it on the host, when it says. Shown, never
  /// resolved by this app.
  final String? path;

  static CommandBrief? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? id = json['brief_id'] ?? json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final Object? path = json['path'];
    return CommandBrief(
      id: id.trim(),
      path: path is String && path.trim().isNotEmpty ? path.trim() : null,
    );
  }
}

/// A planning session the control plane started for a brief.
class CommandSession {
  const CommandSession({required this.name});

  /// The multiplexer session on the host — what the user would attach to, and
  /// what the capture's route record names.
  final String name;

  static CommandSession? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? name = json['tmux_session'] ?? json['session'] ?? json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return CommandSession(name: name.trim());
  }
}

/// Reads the fleet, so a project can be bound to a real `(host, workspace)`.
///
/// A seam of the same shape as `TranscriptionService` and `OcrService`: the
/// disabled default answers "not configured" rather than throwing at
/// construction, so an install that has never seen a control plane behaves
/// exactly as it did before this existed.
///
/// **Read-only, and that is the whole surface for this slice.** Delivering a
/// capture is the next one. Keeping the two apart means binding can be built,
/// used and tested while `CaptureRouter` still has exactly one implementation.
abstract interface class CommandClient {
  /// Whether a base URL is configured at all. Synchronous, because the Config
  /// tab gates a section on it inside `build` — the same rule `canRoute`
  /// follows: destinations are configuration, not state.
  bool get isConfigured;

  Future<List<CommandHost>> hosts();

  Future<List<CommandWorkspace>> workspaces(String hostId);

  /// Files [content] as the brief for [captureId], and answers what the
  /// control plane now holds.
  ///
  /// **Idempotent on `captureId`, and this app depends on that.** The routing
  /// contract is deliver-first-mark-second, so a delivery that times out leaves
  /// the capture open and the user retries it — which must update the brief the
  /// collector already has rather than filing a second copy of one thought.
  Future<CommandBrief> putBrief({
    required String host,
    required String workspace,
    required String captureId,
    required String content,
  });

  /// Starts a planning session on [host] for a brief already filed.
  ///
  /// Separate from [putBrief] because the two fail differently and the
  /// difference matters to the user: a brief that landed with no session is
  /// queued and unstarted, while a brief that never landed is simply lost.
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  });
}

class DisabledCommandClient implements CommandClient {
  const DisabledCommandClient();

  @override
  bool get isConfigured => false;

  @override
  Future<List<CommandHost>> hosts() async =>
      throw const CommandNotConfiguredException();

  @override
  Future<List<CommandWorkspace>> workspaces(String hostId) async =>
      throw const CommandNotConfiguredException();

  @override
  Future<CommandBrief> putBrief({
    required String host,
    required String workspace,
    required String captureId,
    required String content,
  }) async => throw const CommandNotConfiguredException();

  @override
  Future<CommandSession> startSession({
    required String host,
    required String workspace,
    required String briefId,
  }) async => throw const CommandNotConfiguredException();
}

class CommandNotConfiguredException implements Exception {
  const CommandNotConfiguredException();

  @override
  String toString() =>
      'No Command control plane is configured — set its address and fleet '
      'token in the Config tab first.';
}

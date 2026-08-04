import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/projects_repository.dart';
import '../domain/agent_session_launcher.dart';
import '../domain/project.dart';

/// Owns the durable project collection and the transient active-project and
/// launch state used by the Projects tab.
class ProjectsController extends ChangeNotifier {
  ProjectsController({
    ProjectsRepository? repository,
    AgentSessionLauncher? launcher,
    Uuid uuid = const Uuid(),
  }) : _repository = repository ?? ProjectsRepository(),
       _launcher = launcher,
       _uuid = uuid;

  final ProjectsRepository _repository;
  final AgentSessionLauncher? _launcher;
  final Uuid _uuid;

  List<Project> _projects = const <Project>[];
  String? _activeProjectId;
  String? _error;
  bool _isLoading = false;
  final Set<String> _launchesInProgress = <String>{};

  List<Project> get projects => List<Project>.unmodifiable(_projects);
  String? get activeProjectId => _activeProjectId;
  String? get error => _error;
  bool get isLoading => _isLoading;
  bool get canLaunch => _launcher != null;

  Project? get activeProject {
    for (final Project project in _projects) {
      if (project.id == _activeProjectId) return project;
    }
    return null;
  }

  bool isLaunching(String projectId, AgentKind agent) =>
      _launchesInProgress.contains(_launchKey(projectId, agent));

  Future<void> initialize() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _projects = await _repository.loadAll();
      final String? storedActive = _repository.loadedActiveProjectId;
      _activeProjectId =
          _projects.any((Project item) => item.id == storedActive)
          ? storedActive
          : null;
    } catch (exception) {
      _error = exception.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Project> create({
    required String name,
    required String repoPath,
    String? description,
    String? sessionName,
    AgentKind? defaultAgent,
    Map<AgentKind, AgentSettings> agentSettings =
        const <AgentKind, AgentSettings>{},
  }) async {
    final Project project = Project(
      id: _uuid.v4(),
      name: _required(name, 'Project name'),
      repoPath: _required(repoPath, 'Repository path'),
      description: _optional(description),
      sessionName: _optional(sessionName),
      defaultAgent: defaultAgent,
      agentSettings: Map<AgentKind, AgentSettings>.unmodifiable(agentSettings),
    );
    final String nextActive = _activeProjectId ?? project.id;
    await _save(<Project>[..._projects, project], activeProjectId: nextActive);
    return project;
  }

  Future<void> update({
    required Project project,
    required String name,
    required String repoPath,
    String? description,
    String? sessionName,
    AgentKind? defaultAgent,
    Map<AgentKind, AgentSettings>? agentSettings,
  }) async {
    if (!_projects.any((Project item) => item.id == project.id)) {
      throw StateError('Project ${project.id} no longer exists.');
    }
    final Project replacement = Project(
      id: project.id,
      name: _required(name, 'Project name'),
      repoPath: _required(repoPath, 'Repository path'),
      description: _optional(description),
      sessionName: _optional(sessionName),
      defaultAgent: defaultAgent,
      agentSettings: Map<AgentKind, AgentSettings>.unmodifiable(
        agentSettings ?? project.agentSettings,
      ),
    );
    await _save(
      _projects
          .map((Project item) => item.id == project.id ? replacement : item)
          .toList(),
      activeProjectId: _activeProjectId,
    );
  }

  Future<void> delete(String id) async {
    if (!_projects.any((Project item) => item.id == id)) return;
    final List<Project> remaining = _projects
        .where((Project item) => item.id != id)
        .toList();
    final String? nextActive = _activeProjectId == id ? null : _activeProjectId;
    await _save(remaining, activeProjectId: nextActive);
  }

  Future<void> select(String? projectId) async {
    if (projectId != null &&
        !_projects.any((Project item) => item.id == projectId)) {
      throw ArgumentError.value(projectId, 'projectId', 'Unknown project');
    }
    if (_activeProjectId == projectId) return;
    await _save(_projects, activeProjectId: projectId);
  }

  Future<void> launch(Project project, AgentKind agent) async {
    final AgentSessionLauncher? launcher = _launcher;
    if (launcher == null) {
      throw StateError('No agent session launcher is configured.');
    }
    final String key = _launchKey(project.id, agent);
    if (!_launchesInProgress.add(key)) return;
    _error = null;
    notifyListeners();
    try {
      final AgentSettings settings = project.settingsFor(agent);
      await launcher.launch(
        AgentSessionLaunchRequest(
          projectId: project.id,
          projectName: project.name,
          repoPath: project.repoPath,
          agent: _launcherAgent(agent),
          sessionName: project.sessionName,
          arguments: <String>[
            ...settings.additionalArgs,
            if (settings.initialPrompt != null) settings.initialPrompt!,
          ],
        ),
      );
    } catch (exception) {
      _error = exception.toString();
      rethrow;
    } finally {
      _launchesInProgress.remove(key);
      notifyListeners();
    }
  }

  Future<void> _save(
    List<Project> next, {
    required String? activeProjectId,
  }) async {
    _error = null;
    try {
      await _repository.saveAll(next, activeProjectId: activeProjectId);
      _projects = List<Project>.unmodifiable(next);
      _activeProjectId = activeProjectId;
      notifyListeners();
    } catch (exception) {
      _error = exception.toString();
      notifyListeners();
      rethrow;
    }
  }

  static String _required(String value, String label) {
    final String normalized = value.trim();
    if (normalized.isEmpty) throw ArgumentError('$label is required.');
    return normalized;
  }

  static String? _optional(String? value) {
    final String normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static String _launchKey(String projectId, AgentKind agent) =>
      '$projectId:${agent.name}';

  static ProjectAgent _launcherAgent(AgentKind agent) => switch (agent) {
    AgentKind.codex => ProjectAgent.codex,
    AgentKind.claudeCode => ProjectAgent.claude,
    AgentKind.gemini => ProjectAgent.gemini,
  };
}

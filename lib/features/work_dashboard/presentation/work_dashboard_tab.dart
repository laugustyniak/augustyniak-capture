import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/ui_kit.dart';
import '../../../core/security/app_secure_storage.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_controller.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../../timer/presentation/focus_timer_controller.dart';
import '../data/todoist_reader.dart';

/// A local read-only view of Todoist work and Capture context.
class WorkDashboardTab extends StatefulWidget {
  const WorkDashboardTab({
    super.key,
    required this.projects,
    required this.recordings,
    required this.timer,
    required this.active,
    this.onNavigateToQueue,
    this.reader,
  });

  final ProjectsController projects;
  final RecordingsController recordings;
  final FocusTimerController timer;
  final bool active;
  final ValueChanged<String>? onNavigateToQueue;
  final TodoistReader? reader;

  @override
  State<WorkDashboardTab> createState() => _WorkDashboardTabState();
}

class _WorkDashboardTabState extends State<WorkDashboardTab> {
  static const String _credentialEntry = 'todoist_read_token';
  static const String _linksKey = 'todoist_capture_project_links';

  late final TodoistReader _reader = widget.reader ?? TodoistReader();
  final TextEditingController _tokenInput = TextEditingController();
  String? _token;
  Map<String, String> _links = <String, String>{};
  TodoistSnapshot? _snapshot;
  String? _selectedProjectId;
  String? _error;
  bool _loading = false;
  bool _ready = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _startWhenActive();
  }

  @override
  void didUpdateWidget(covariant WorkDashboardTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _startWhenActive();
  }

  void _startWhenActive() {
    if (!widget.active || _started) return;
    _started = true;
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _tokenInput.dispose();
    if (widget.reader == null) _reader.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final String? token = await AppSecureStorage.instance.read(
        key: _credentialEntry,
      );
      final String? storedLinks = await AppSecureStorage.instance.read(
        key: _linksKey,
      );
      if (!mounted) return;
      final Object? decoded = storedLinks == null
          ? null
          : jsonDecode(storedLinks);
      setState(() {
        _token = token;
        if (decoded is Map<String, dynamic>) {
          _links = decoded.map(
            (String key, dynamic value) => MapEntry(key, value.toString()),
          );
        }
        _ready = true;
      });
      if (token != null && token.isNotEmpty) await _refresh();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = 'Secure storage is unavailable. Todoist is not connected.';
      });
    }
  }

  Future<void> _connect() async {
    final String token = _tokenInput.text.trim();
    if (token.isEmpty) return;
    try {
      // Validate before persisting. The token never enters settings.json.
      setState(() {
        _loading = true;
        _error = null;
      });
      final TodoistSnapshot snapshot = await _reader.load(token);
      await AppSecureStorage.instance.write(key: _credentialEntry, value: token);
      if (!mounted) return;
      _tokenInput.clear();
      setState(() {
        _token = token;
        _snapshot = snapshot;
        _selectedProjectId = _initialProjectId(snapshot);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await AppSecureStorage.instance.delete(key: _credentialEntry);
      await AppSecureStorage.instance.delete(key: _linksKey);
      if (!mounted) return;
      setState(() {
        _token = null;
        _snapshot = null;
        _selectedProjectId = null;
        _links = <String, String>{};
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not remove the Todoist token.');
      }
    }
  }

  Future<void> _refresh() async {
    final String? token = _token;
    if (token == null || token.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final TodoistSnapshot snapshot = await _reader.load(token);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedProjectId =
            snapshot.projects.any(
              (TodoistProject project) => project.id == _selectedProjectId,
            )
            ? _selectedProjectId
            : _initialProjectId(snapshot);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _initialProjectId(TodoistSnapshot snapshot) {
    final Set<String> known = widget.projects.projects
        .map((Project project) => project.name.toLowerCase())
        .toSet();
    for (final TodoistProject project in snapshot.projects) {
      if (known.contains(project.name.toLowerCase())) return project.id;
    }
    return snapshot.dueTasks.isEmpty ? null : snapshot.dueTasks.first.projectId;
  }

  Future<void> _linkProject(String? captureProjectId) async {
    final String? todoistProjectId = _selectedProjectId;
    if (todoistProjectId == null) return;
    final Map<String, String> next = <String, String>{..._links};
    if (captureProjectId == null) {
      next.remove(todoistProjectId);
    } else {
      next[todoistProjectId] = captureProjectId;
    }
    try {
      await AppSecureStorage.instance.write(
        key: _linksKey,
        value: jsonEncode(next),
      );
      if (mounted) setState(() => _links = next);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save project mapping.');
    }
  }

  List<TodoistTask> _focusTasks(TodoistSnapshot snapshot) {
    final Map<String, TodoistTask> unique = <String, TodoistTask>{};
    final List<TodoistTask> founder = snapshot.founderTasks.toList()
      ..sort(
        (TodoistTask a, TodoistTask b) => b.priority.compareTo(a.priority),
      );
    for (final TodoistTask task in founder.take(5)) {
      unique[task.id] = task;
    }
    final List<TodoistTask> urgent =
        snapshot.dueTasks
            .where((TodoistTask task) => task.priority >= 3)
            .toList()
          ..sort(
            (TodoistTask a, TodoistTask b) => b.priority.compareTo(a.priority),
          );
    for (final TodoistTask task in urgent) {
      if (unique.length >= 8) break;
      unique[task.id] = task;
    }
    return unique.values.toList(growable: false);
  }

  bool _isOverdue(TodoistTask task) {
    final String? due = task.dueDate;
    if (due == null) return false;
    final DateTime? parsed = DateTime.tryParse(due);
    if (parsed == null) return false;
    final DateTime local = parsed.isUtc ? parsed.toLocal() : parsed;
    final DateTime today = DateTime.now();
    return DateTime(
      local.year,
      local.month,
      local.day,
    ).isBefore(DateTime(today.year, today.month, today.day));
  }

  String? get _mappedCaptureProjectId {
    final String? id = _links[_selectedProjectId];
    return widget.projects.projects.any((Project project) => project.id == id)
        ? id
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final TodoistSnapshot? snapshot = _snapshot;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(title: 'Work', trailing: 'TODOIST + CAPTURE'),
          const SizedBox(height: 16),
          if (_error != null) ...<Widget>[
            ErrorBanner(message: _error!),
            const SizedBox(height: 12),
          ],
          if (!_ready || (_loading && snapshot == null && _token != null))
            const Center(child: CircularProgressIndicator())
          else if (_token == null || _token!.isEmpty)
            _connectionCard()
          else ...<Widget>[
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(_loading ? 'REFRESHING' : 'REFRESH'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _disconnect,
                  child: const Text('DISCONNECT'),
                ),
              ],
            ),
            if (snapshot != null) ...<Widget>[
              Text(
                'Updated ${snapshot.fetchedAt.toLocal()} · read only',
                style: TextStyle(color: Console.dimText),
              ),
              const SizedBox(height: 18),
              SectionHeader(
                title: 'FOCUS',
                trailing:
                    '${snapshot.dueTasks.where(_isOverdue).length} OVERDUE · '
                    '${snapshot.dueTasks.where((TodoistTask task) => !_isOverdue(task)).length} TODAY',
              ),
              const SizedBox(height: 8),
              ..._focusTasks(snapshot).map(_taskTile),
              if (_focusTasks(snapshot).isEmpty)
                const Text('No founder or high-priority due tasks.'),
              const SizedBox(height: 22),
              SectionHeader(title: 'PROJECT CONTEXT'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey<String?>(_selectedProjectId),
                initialValue: _selectedProjectId,
                decoration: const InputDecoration(labelText: 'Todoist project'),
                items: snapshot.projects
                    .map(
                      (TodoistProject project) => DropdownMenuItem<String>(
                        value: project.id,
                        child: Text(project.name),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) =>
                    setState(() => _selectedProjectId = value),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                isExpanded: true,
                key: ValueKey<String>(
                  'capture-link:$_selectedProjectId:$_mappedCaptureProjectId',
                ),
                initialValue: _mappedCaptureProjectId,
                decoration: const InputDecoration(labelText: 'Capture project'),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No mapping'),
                  ),
                  ...widget.projects.projects.map(
                    (Project project) => DropdownMenuItem<String?>(
                      value: project.id,
                      child: Text(project.name),
                    ),
                  ),
                ],
                onChanged: _linkProject,
              ),
              const SizedBox(height: 10),
              ...<String, TodoistTask>{
                for (final TodoistTask task in snapshot.founderTasks)
                  if (task.projectId == _selectedProjectId) task.id: task,
                for (final TodoistTask task in snapshot.dueTasks)
                  if (task.projectId == _selectedProjectId) task.id: task,
              }.values.take(8).map(_taskTile),
              _captureContext(),
            ],
          ],
        ],
      ),
    );
  }

  Widget _connectionCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('Connect Todoist to see your current work here.'),
          const SizedBox(height: 10),
          TextField(
            controller: _tokenInput,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Personal API token'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _loading ? null : _connect,
            child: const Text('CONNECT'),
          ),
          const Text(
            'Find the token in Todoist Settings → Integrations → Developer. '
            'It stays in the OS keyring; Capture reads Todoist only.',
          ),
        ],
      ),
    ),
  );

  Widget _taskTile(TodoistTask task) => Card(
    child: ListTile(
      dense: true,
      title: Text(task.content, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        <String>[
          for (final TodoistProject project
              in _snapshot?.projects ?? const <TodoistProject>[])
            if (project.id == task.projectId) project.name,
          if (task.dueDate != null) task.dueDate!,
          'P${5 - task.priority}',
        ].join(' · '),
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => launchUrl(task.url),
    ),
  );

  Widget _captureContext() {
    final String? captureProjectId = _mappedCaptureProjectId;
    if (captureProjectId == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Map this project to show related Capture work.'),
      );
    }
    final List<Recording> captures =
        widget.recordings.recordings
            .where(
              (Recording recording) => recording.projectId == captureProjectId,
            )
            .toList()
          ..sort(
            (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
          );
    final sessions = widget.timer.sessions
        .where((session) => session.projectId == captureProjectId)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 14),
        Text(
          '${captures.length} captures · ${sessions.length} completed focus sessions',
        ),
        if (widget.timer.isLive &&
            widget.projects.activeProjectId == captureProjectId &&
            widget.timer.goal.trim().isNotEmpty)
          Text('Current focus: ${widget.timer.goal}'),
        ...captures
            .take(5)
            .map(
              (Recording recording) => ListTile(
                dense: true,
                title: Text(
                  recording.title?.trim().isNotEmpty == true
                      ? recording.title!
                      : 'Capture ${recording.createdAt.toLocal()}',
                ),
                subtitle: Text(recording.createdAt.toLocal().toString()),
                onTap: widget.onNavigateToQueue == null
                    ? null
                    : () => widget.onNavigateToQueue!(captureProjectId),
              ),
            ),
      ],
    );
  }
}

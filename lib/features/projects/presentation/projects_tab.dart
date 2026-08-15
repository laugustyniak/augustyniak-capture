import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../../command/domain/command_client.dart';
import '../data/directory_picker.dart';
import '../domain/project.dart';
import 'project_captures_sheet.dart';
import 'projects_controller.dart';

/// Project registry and the explicit entry point for opening coding-agent
/// sessions in a repository context.
class ProjectsTab extends StatelessWidget {
  const ProjectsTab({
    super.key,
    required this.controller,
    this.recordingsController,
    this.directoryPicker = const FilePickerDirectoryPicker(),
    this.commandClient = const DisabledCommandClient(),
    this.onNavigateToQueue,
  });

  final ProjectsController controller;
  final RecordingsController? recordingsController;

  /// Fills the repository-path field from a native folder dialog. Injectable so
  /// the widget suite never reaches `file_picker`'s platform channel.
  final DirectoryPicker directoryPicker;

  /// Reads the fleet so a project can be bound to a real `(host, workspace)`.
  /// Defaults to the disabled client, so a host that has configured no control
  /// plane — and every widget test — renders the editor exactly as before.
  final CommandClient commandClient;

  final ValueChanged<String>? onNavigateToQueue;

  @override
  Widget build(BuildContext context) {
    final List<Project> projects = controller.projects;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: <Widget>[
          ConsoleHeader(
            title: 'Projects',
            trailing:
                '${projects.length} ${projects.length == 1 ? 'project' : 'projects'}',
          ),
          const SizedBox(height: 18),
          if (controller.error != null) ...<Widget>[
            ErrorBanner(message: controller.error!),
            const SizedBox(height: 12),
          ],
          SectionHeader(title: 'WORKSPACES', trailing: 'REPOSITORY CONTEXT'),
          const SizedBox(height: 12),
          if (controller.isLoading && projects.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(color: Console.accent),
              ),
            )
          else if (projects.isEmpty)
            EmptyPanel(
              icon: Icons.folder_open_outlined,
              title: 'No projects yet.',
              blurb:
                  'Register a repository once, then open Codex, Claude Code '
                  'or Antigravity with the right working directory and context.',
            )
          else
            ...projects.map(
              (Project project) {
                final int count = recordingsController?.recordings
                        .where((Recording r) => r.projectId == project.id)
                        .length ??
                    0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: _ProjectCard(
                    key: ValueKey<String>('project-${project.id}'),
                    project: project,
                    controller: controller,
                    active: controller.activeProjectId == project.id,
                    onSelect: () => _select(context, project),
                    onEdit: () => _openEditor(context, project),
                    onDelete: () => _confirmDelete(context, project),
                    onViewCaptures: () => _openCaptures(context, project),
                    capturesCount: count,
                  ),
                );
              },
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey<String>('add-project'),
            onPressed: () => _openEditor(context, null),
            style: FilledButton.styleFrom(
              backgroundColor: Console.accent,
              foregroundColor: Console.ink,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text(
              'ADD PROJECT',
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: .5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCaptures(BuildContext context, Project project) async {
    if (recordingsController == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => ProjectCapturesSheet(
          project: project,
          recordingsController: recordingsController!,
          projectsController: controller,
          onNavigateToQueue: onNavigateToQueue,
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, Project? existing) async {
    final _ProjectDraft? draft = await showModalBottomSheet<_ProjectDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (BuildContext context) => ConsolePaletteScope(
        builder: (BuildContext context) => _ProjectEditorSheet(
          existing: existing,
          directoryPicker: directoryPicker,
          commandClient: commandClient,
        ),
      ),
    );
    // Persisting belongs to the controller and does not require a live widget
    // context. The tab may be rebuilt while the modal route is closing.
    if (draft == null) return;
    try {
      if (existing == null) {
        await controller.create(
          name: draft.name,
          repoPath: draft.repoPath,
          description: draft.description,
          sessionName: draft.sessionName,
          defaultAgent: draft.defaultAgent,
          agentSettings: draft.agentSettings,
          commandHost: draft.commandHost,
          commandWorkspace: draft.commandWorkspace,
        );
      } else {
        await controller.update(
          project: existing,
          name: draft.name,
          repoPath: draft.repoPath,
          description: draft.description,
          sessionName: draft.sessionName,
          defaultAgent: draft.defaultAgent,
          agentSettings: draft.agentSettings,
          commandHost: draft.commandHost,
          commandWorkspace: draft.commandWorkspace,
        );
      }
    } catch (exception) {
      if (context.mounted) _showFailure(context, exception);
    }
  }

  Future<void> _confirmDelete(BuildContext context, Project project) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete ${project.name}?',
      message:
          'The project configuration will be removed. The repository and '
          'its files stay untouched.',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    try {
      await controller.delete(project.id);
    } catch (exception) {
      if (context.mounted) _showFailure(context, exception);
    }
  }

  Future<void> _select(BuildContext context, Project project) async {
    try {
      await controller.select(project.id);
    } catch (exception) {
      if (context.mounted) _showFailure(context, exception);
    }
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    super.key,
    required this.project,
    required this.controller,
    required this.active,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    this.onViewCaptures,
    this.capturesCount = 0,
  });

  final Project project;
  final ProjectsController controller;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onViewCaptures;
  final int capturesCount;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      accent: active ? Console.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewCaptures,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Console.iconTile,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.account_tree_outlined,
                      color: Console.accent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                project.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ConsoleText.cardTitle,
                              ),
                            ),
                            if (active) ...<Widget>[
                              const SizedBox(width: 8),
                              StatusPill(label: 'ACTIVE', color: Console.accent),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          project.repoPath,
                          maxLines: 2,
                          style: ConsoleText.cardMeta,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Project actions',
                    color: Console.surfaceRaised,
                    iconColor: Console.mutedSoft,
                    onSelected: (String value) {
                      if (value == 'edit') onEdit();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (BuildContext context) =>
                        const <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                  ),
                ],
              ),
            ),
          ),
          if (project.description != null &&
              project.description!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(project.description!, style: ConsoleText.body),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (!active)
                OutlinedButton.icon(
                  onPressed: onSelect,
                  icon: const Icon(Icons.radio_button_unchecked, size: 16),
                  label: const Text('SET ACTIVE'),
                ),
              if (onViewCaptures != null)
                OutlinedButton.icon(
                  key: ValueKey<String>('project-captures-${project.id}'),
                  onPressed: onViewCaptures,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Console.accent,
                    side: BorderSide(
                      color: Console.accent.withValues(alpha: .5),
                    ),
                  ),
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: Text('CAPTURES ($capturesCount)'),
                ),
              ...AgentKind.values.map(
                (AgentKind agent) => _AgentButton(
                  project: project,
                  agent: agent,
                  controller: controller,
                  preferred: project.defaultAgent == agent,
                ),
              ),
            ],
          ),
          if (project.sessionName != null &&
              project.sessionName!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text('SESSION  ${project.sessionName}', style: ConsoleText.micro),
          ],
        ],
      ),
    );
  }
}

class _AgentButton extends StatelessWidget {
  const _AgentButton({
    required this.project,
    required this.agent,
    required this.controller,
    required this.preferred,
  });

  final Project project;
  final AgentKind agent;
  final ProjectsController controller;
  final bool preferred;

  @override
  Widget build(BuildContext context) {
    final bool launching = controller.isLaunching(project.id, agent);
    return OutlinedButton.icon(
      key: ValueKey<String>('launch-${project.id}-${agent.name}'),
      onPressed: !controller.canLaunch || launching
          ? null
          : () async {
              try {
                await controller.launch(project, agent);
              } catch (exception) {
                if (context.mounted) _showFailure(context, exception);
              }
            },
      style: OutlinedButton.styleFrom(
        foregroundColor: preferred ? Console.accent : Console.textSoft,
        side: BorderSide(
          color: preferred ? Console.accent : Console.borderStrong,
        ),
      ),
      icon: launching
          ? const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_agentIcon(agent), size: 16),
      label: Text(_agentLabel(agent).toUpperCase()),
    );
  }
}

class _ProjectEditorSheet extends StatefulWidget {
  const _ProjectEditorSheet({
    required this.existing,
    required this.directoryPicker,
    required this.commandClient,
  });

  final Project? existing;
  final DirectoryPicker directoryPicker;
  final CommandClient commandClient;

  @override
  State<_ProjectEditorSheet> createState() => _ProjectEditorSheetState();
}

class _ProjectEditorSheetState extends State<_ProjectEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name,
  );
  late final TextEditingController _repoPath = TextEditingController(
    text: widget.existing?.repoPath,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.existing?.description,
  );
  late final TextEditingController _sessionName = TextEditingController(
    text: widget.existing?.sessionName,
  );
  late final Map<AgentKind, TextEditingController> _arguments;
  late final Map<AgentKind, TextEditingController> _prompts;
  late AgentKind? _defaultAgent = widget.existing?.defaultAgent;

  /// The binding, held as the two strings that address work rather than as the
  /// objects they were picked from: the fleet's labels are for reading and its
  /// ids are what `projects.json` stores.
  late String? _commandHost = widget.existing?.commandHost;
  late String? _commandWorkspace = widget.existing?.commandWorkspace;

  /// Loaded on demand, never on open. A sheet that fired an HTTP request every
  /// time somebody edited a project name would make an unreachable control
  /// plane a delay on renaming a project.
  List<CommandHost>? _hosts;
  List<CommandWorkspace>? _workspaces;
  bool _loadingFleet = false;
  String? _fleetError;

  /// A folder dialog that refuses is reported in the sheet rather than swallowed
  /// — the field still accepts a typed path, so the failure must not look like
  /// a dead button. The app uses no snackbars, so this stays inline.
  String? _browseError;

  @override
  void initState() {
    super.initState();
    _arguments = <AgentKind, TextEditingController>{
      for (final AgentKind agent in AgentKind.values)
        agent: TextEditingController(
          text: widget.existing?.settingsFor(agent).additionalArgs.join('\n'),
        ),
    };
    _prompts = <AgentKind, TextEditingController>{
      for (final AgentKind agent in AgentKind.values)
        agent: TextEditingController(
          text: widget.existing?.settingsFor(agent).initialPrompt,
        ),
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _repoPath.dispose();
    _description.dispose();
    _sessionName.dispose();
    for (final TextEditingController controller in <TextEditingController>[
      ..._arguments.values,
      ..._prompts.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.existing == null ? 'Add project' : 'Edit project',
                style: ConsoleText.pageTitle.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 5),
              Text(
                'Repository context for content and coding-agent sessions.',
                style: ConsoleText.micro,
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const ValueKey<String>('project-name-field'),
                controller: _name,
                autofocus: widget.existing == null,
                decoration: const InputDecoration(labelText: 'Project name'),
                textInputAction: TextInputAction.next,
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey<String>('project-repo-path-field'),
                controller: _repoPath,
                decoration: InputDecoration(
                  labelText: 'Repository path',
                  hintText: '/Users/you/github/apps/project',
                  suffixIcon: widget.directoryPicker.isAvailable
                      ? IconButton(
                          key: const ValueKey<String>(
                            'project-repo-path-browse',
                          ),
                          tooltip: 'Choose directory',
                          icon: Icon(
                            Icons.folder_open_outlined,
                            color: Console.accent,
                            size: 20,
                          ),
                          onPressed: _browseForRepository,
                        )
                      : null,
                ),
                textInputAction: TextInputAction.next,
                validator: _required,
              ),
              if (_browseError != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  _browseError!,
                  style: ConsoleText.micro.copyWith(color: Console.amber),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Purpose, architecture and current focus',
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _sessionName,
                decoration: const InputDecoration(
                  labelText: 'Session name (optional)',
                  hintText: 'augustyniak',
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 18),
              SectionHeader(title: 'DEFAULT AGENT'),
              const SizedBox(height: 9),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('NONE'),
                    selected: _defaultAgent == null,
                    onSelected: (_) => setState(() => _defaultAgent = null),
                  ),
                  ...AgentKind.values.map(
                    (AgentKind agent) => ChoiceChip(
                      label: Text(_agentLabel(agent).toUpperCase()),
                      selected: _defaultAgent == agent,
                      onSelected: (_) => setState(() => _defaultAgent = agent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandBinding(
                client: widget.commandClient,
                host: _commandHost,
                workspace: _commandWorkspace,
                hosts: _hosts,
                workspaces: _workspaces,
                loading: _loadingFleet,
                error: _fleetError,
                onLoadHosts: _loadHosts,
                onPickHost: _pickHost,
                onPickWorkspace: (String name) =>
                    setState(() => _commandWorkspace = name),
                onUnbind: () => setState(() {
                  _commandHost = null;
                  _commandWorkspace = null;
                  _workspaces = null;
                }),
              ),
              const SizedBox(height: 18),
              SectionHeader(title: 'AGENT SETTINGS'),
              const SizedBox(height: 9),
              ...AgentKind.values.map(
                (AgentKind agent) => ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  title: Text(
                    _agentLabel(agent).toUpperCase(),
                    style: ConsoleText.chip,
                  ),
                  subtitle: Text(
                    'Structured arguments and optional initial prompt',
                    style: ConsoleText.micro,
                  ),
                  children: <Widget>[
                    TextFormField(
                      controller: _arguments[agent],
                      decoration: const InputDecoration(
                        labelText: 'Additional arguments — one per line',
                        hintText: '--model\nsonnet',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _prompts[agent],
                      decoration: const InputDecoration(
                        labelText: 'Initial prompt (optional)',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCEL'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey<String>('save-project'),
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: Console.accent,
                        foregroundColor: Console.ink,
                      ),
                      child: const Text('SAVE'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fills the path field from a native folder dialog. The typed value stays
  /// authoritative: a cancel leaves it untouched, and the dialog opens at the
  /// current path so editing an existing project starts where it already points.
  Future<void> _browseForRepository() async {
    final String current = _repoPath.text.trim();
    try {
      final String? chosen = await widget.directoryPicker.pick(
        initialDirectory: current.isEmpty ? null : current,
      );
      if (!mounted || chosen == null) return;
      setState(() {
        _repoPath.text = chosen;
        _browseError = null;
      });
      // The field may already have been marked invalid by an earlier submit.
      _formKey.currentState?.validate();
    } catch (exception) {
      if (!mounted) return;
      setState(() => _browseError = 'Folder dialog failed: $exception');
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ProjectDraft(
        name: _name.text,
        repoPath: _repoPath.text,
        description: _description.text,
        sessionName: _sessionName.text,
        defaultAgent: _defaultAgent,
        commandHost: _commandHost,
        commandWorkspace: _commandWorkspace,
        agentSettings: <AgentKind, AgentSettings>{
          for (final AgentKind agent in AgentKind.values)
            if (_settingsFor(agent) case final AgentSettings settings
                when !settings.isEmpty)
              agent: settings,
        },
      ),
    );
  }

  Future<void> _loadHosts() async {
    if (_loadingFleet) return;
    setState(() {
      _loadingFleet = true;
      _fleetError = null;
    });
    try {
      final List<CommandHost> hosts = await widget.commandClient.hosts();
      if (!mounted) return;
      setState(() => _hosts = hosts);
    } catch (exception) {
      // Inline, like the directory picker's failure and for the same reason: a
      // control that answers nothing is indistinguishable from a dead one, and
      // this app uses no snackbars.
      if (!mounted) return;
      setState(() => _fleetError = exception.toString());
    } finally {
      if (mounted) setState(() => _loadingFleet = false);
    }
  }

  /// Choosing a host drops the workspace with it. A workspace belongs to the
  /// host it was listed from, so carrying it across would leave a pair that
  /// names a checkout the new host has never heard of — the exact drift two
  /// live pickers exist to prevent.
  Future<void> _pickHost(String id) async {
    setState(() {
      _commandHost = id;
      _commandWorkspace = null;
      _workspaces = null;
      _loadingFleet = true;
      _fleetError = null;
    });
    try {
      final List<CommandWorkspace> spaces = await widget.commandClient
          .workspaces(id);
      if (!mounted) return;
      setState(() => _workspaces = spaces);
    } catch (exception) {
      if (!mounted) return;
      setState(() => _fleetError = exception.toString());
    } finally {
      if (mounted) setState(() => _loadingFleet = false);
    }
  }

  AgentSettings _settingsFor(AgentKind agent) {
    final List<String> arguments = _arguments[agent]!.text
        .split(RegExp(r'\r?\n'))
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final String prompt = _prompts[agent]!.text.trim();
    return AgentSettings(
      additionalArgs: arguments,
      initialPrompt: prompt.isEmpty ? null : prompt,
    );
  }

  static String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;
}

class _ProjectDraft {
  const _ProjectDraft({
    required this.name,
    required this.repoPath,
    required this.description,
    required this.sessionName,
    required this.defaultAgent,
    required this.agentSettings,
    this.commandHost,
    this.commandWorkspace,
  });

  final String name;
  final String repoPath;
  final String description;
  final String sessionName;
  final AgentKind? defaultAgent;
  final Map<AgentKind, AgentSettings> agentSettings;

  /// Null on either half means unbound — the controller clears all three
  /// fields rather than storing a pair that cannot address anything.
  final String? commandHost;
  final String? commandWorkspace;
}

String _agentLabel(AgentKind agent) => switch (agent) {
  AgentKind.codex => 'Codex',
  AgentKind.claudeCode => 'Claude Code',
  AgentKind.antigravity => 'Antigravity',
};

IconData _agentIcon(AgentKind agent) => switch (agent) {
  AgentKind.codex => Icons.code,
  AgentKind.claudeCode => Icons.terminal,
  AgentKind.antigravity => Icons.auto_awesome,
};

void _showFailure(BuildContext context, Object exception) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(exception.toString())));
}

/// Binds a project to a `(host, workspace)` on the Command control plane.
///
/// **Two pickers over live reads, never a typed name.** A typed workspace is a
/// third source of truth with nothing to validate it against, and it drifts
/// from the fleet the first time a checkout is renamed — which is the failure
/// this binding exists to prevent. So the only way to set one here is to pick
/// it out of what the control plane just said it has.
///
/// Stateless: every piece of state belongs to the editor sheet, which is what
/// carries it into the draft on save. Cancelling the sheet therefore discards a
/// binding exactly as it discards a renamed project.
class _CommandBinding extends StatelessWidget {
  _CommandBinding({
    required this.client,
    required this.host,
    required this.workspace,
    required this.hosts,
    required this.workspaces,
    required this.loading,
    required this.error,
    required this.onLoadHosts,
    required this.onPickHost,
    required this.onPickWorkspace,
    required this.onUnbind,
  });

  final CommandClient client;
  final String? host;
  final String? workspace;
  final List<CommandHost>? hosts;
  final List<CommandWorkspace>? workspaces;
  final bool loading;
  final String? error;
  final Future<void> Function() onLoadHosts;
  final Future<void> Function(String id) onPickHost;
  final ValueChanged<String> onPickWorkspace;
  final VoidCallback onUnbind;

  bool get _bound =>
      (host?.isNotEmpty ?? false) && (workspace?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    if (!client.isConfigured) {
      // Said rather than hidden: an absent section is indistinguishable from a
      // feature this build does not have, and the fix is two fields away.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(title: 'COMMAND BINDING'),
          const SizedBox(height: 9),
          Text(
            'No control plane configured. Set its address in Config to bind '
            'this project to a host and workspace.',
            style: ConsoleText.micro,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: 'COMMAND BINDING'),
        const SizedBox(height: 9),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _bound ? '$host · $workspace' : 'Not bound — work stays local.',
                style: ConsoleText.micro.copyWith(
                  color: _bound ? Console.accent : Console.dimText,
                ),
              ),
            ),
            if (_bound)
              TextButton(onPressed: onUnbind, child: const Text('UNBIND')),
            TextButton(
              onPressed: loading ? null : onLoadHosts,
              child: Text(loading ? 'LOADING…' : 'HOSTS'),
            ),
          ],
        ),
        if (hosts != null) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final CommandHost item in hosts!)
                ChoiceChip(
                  label: Text(item.label),
                  selected: host == item.id,
                  onSelected: (_) => onPickHost(item.id),
                ),
              if (hosts!.isEmpty)
                Text('No hosts registered.', style: ConsoleText.micro),
            ],
          ),
        ],
        if (workspaces != null) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final CommandWorkspace item in workspaces!)
                ChoiceChip(
                  label: Text(item.name),
                  selected: workspace == item.name,
                  onSelected: (_) => onPickWorkspace(item.name),
                ),
              if (workspaces!.isEmpty)
                Text('No workspaces on this host.', style: ConsoleText.micro),
            ],
          ),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(error!, style: ConsoleText.micro.copyWith(color: Console.red)),
        ],
      ],
    );
  }
}

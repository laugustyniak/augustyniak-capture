import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/project.dart';
import 'projects_controller.dart';

/// Project registry and the explicit entry point for opening coding-agent
/// sessions in a repository context.
class ProjectsTab extends StatelessWidget {
  const ProjectsTab({super.key, required this.controller});

  final ProjectsController controller;

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
          const SectionHeader(
            title: 'WORKSPACES',
            trailing: 'REPOSITORY CONTEXT',
          ),
          const SizedBox(height: 12),
          if (controller.isLoading && projects.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(color: Console.cyan),
              ),
            )
          else if (projects.isEmpty)
            const EmptyPanel(
              icon: Icons.folder_open_outlined,
              title: 'No projects yet.',
              blurb:
                  'Register a repository once, then open Codex, Claude Code '
                  'or Gemini with the right working directory and context.',
            )
          else
            ...projects.map(
              (Project project) => Padding(
                padding: const EdgeInsets.only(bottom: 11),
                child: _ProjectCard(
                  key: ValueKey<String>('project-${project.id}'),
                  project: project,
                  controller: controller,
                  active: controller.activeProjectId == project.id,
                  onSelect: () => _select(context, project),
                  onEdit: () => _openEditor(context, project),
                  onDelete: () => _confirmDelete(context, project),
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey<String>('add-project'),
            onPressed: () => _openEditor(context, null),
            style: FilledButton.styleFrom(
              backgroundColor: Console.cyan,
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

  Future<void> _openEditor(BuildContext context, Project? existing) async {
    final _ProjectDraft? draft = await showModalBottomSheet<_ProjectDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Console.surfaceDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (BuildContext context) =>
          _ProjectEditorSheet(existing: existing),
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
  });

  final Project project;
  final ProjectsController controller;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      accent: active ? Console.cyan : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Console.iconTile,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.account_tree_outlined,
                  color: Console.cyan,
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
                          const StatusPill(
                            label: 'ACTIVE',
                            color: Console.cyan,
                          ),
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
        foregroundColor: preferred ? Console.cyan : Console.textSoft,
        side: BorderSide(
          color: preferred ? Console.cyan : Console.borderStrong,
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
  const _ProjectEditorSheet({required this.existing});

  final Project? existing;

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
                decoration: const InputDecoration(
                  labelText: 'Repository path',
                  hintText: '/Users/you/github/apps/project',
                ),
                textInputAction: TextInputAction.next,
                validator: _required,
              ),
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
                  hintText: 'audivoa',
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 18),
              const SectionHeader(title: 'DEFAULT AGENT'),
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
              const SectionHeader(title: 'AGENT SETTINGS'),
              const SizedBox(height: 9),
              ...AgentKind.values.map(
                (AgentKind agent) => ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  title: Text(
                    _agentLabel(agent).toUpperCase(),
                    style: ConsoleText.chip,
                  ),
                  subtitle: const Text(
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
                        backgroundColor: Console.cyan,
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
        agentSettings: <AgentKind, AgentSettings>{
          for (final AgentKind agent in AgentKind.values)
            if (_settingsFor(agent) case final AgentSettings settings
                when !settings.isEmpty)
              agent: settings,
        },
      ),
    );
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
  });

  final String name;
  final String repoPath;
  final String description;
  final String sessionName;
  final AgentKind? defaultAgent;
  final Map<AgentKind, AgentSettings> agentSettings;
}

String _agentLabel(AgentKind agent) => switch (agent) {
  AgentKind.codex => 'Codex',
  AgentKind.claudeCode => 'Claude Code',
  AgentKind.gemini => 'Gemini',
};

IconData _agentIcon(AgentKind agent) => switch (agent) {
  AgentKind.codex => Icons.code,
  AgentKind.claudeCode => Icons.terminal,
  AgentKind.gemini => Icons.auto_awesome,
};

void _showFailure(BuildContext context, Object exception) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(exception.toString())));
}

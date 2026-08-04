import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../enrichment/domain/enrichment_context.dart';
import '../../projects/data/project_context_probe.dart';
import '../../projects/data/project_context_reader.dart';
import '../../projects/domain/project.dart';
import 'settings_controller.dart';

/// The "who I am" text handed to the enrichment model with every capture, plus
/// a read-only report of what each project's repository currently contributes.
///
/// Stateful for the same reason `RecordingEditor` is: the field has to survive
/// the controller's notifications, and a background write must never overwrite
/// what someone is halfway through typing.
class EnrichmentContextSection extends StatefulWidget {
  const EnrichmentContextSection({
    super.key,
    required this.controller,
    this.projects = const <Project>[],
  });

  final SettingsController controller;

  /// Empty by default, and that default is what keeps this widget free of disk
  /// access: with no projects there is nothing to probe, so the existing Config
  /// tests never touch the filesystem. The shell passes the real list.
  final List<Project> projects;

  @override
  State<EnrichmentContextSection> createState() =>
      _EnrichmentContextSectionState();
}

class _EnrichmentContextSectionState extends State<EnrichmentContextSection> {
  late final TextEditingController _field = TextEditingController(
    text: _stored,
  );
  final FocusNode _focus = FocusNode();

  /// The last value taken *from* settings. Dirty is a difference from this, not
  /// from the settings object — which is what lets a save land without the
  /// field flickering, and stops a reload from clobbering an in-progress edit.
  late String _synced = _stored;

  /// What each project would send right now, by project id. Absent while the
  /// scan runs — the row says so rather than rendering a misleading "none".
  Map<String, ProjectContextStatus> _statuses =
      <String, ProjectContextStatus>{};
  bool _scanning = false;

  static const ProjectContextProbe _probe = ProjectContextProbe(
    sendLimit: EnrichmentContext.maxProjectChars,
  );

  /// Never null — an untouched install resolves to the shipped default, so the
  /// box is populated on first run rather than empty.
  String get _stored => widget.controller.enrichmentInstructions;
  bool get _dirty => _field.text.trim() != _synced.trim();

  @override
  void initState() {
    super.initState();
    _scan();
    // Commit on blur, like every other field in this app. There is no SAVE for
    // text elsewhere either; the amber UNSAVED marker is the safety net that
    // keeps "saved when you looked away" from being indistinguishable from
    // "lost your edit".
    _focus.addListener(() {
      if (!_focus.hasFocus && _dirty) _commit();
    });
  }

  @override
  void didUpdateWidget(EnrichmentContextSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt an external change only while the field is clean.
    if (_stored != _synced && !_dirty) {
      _synced = _stored;
      _field.text = _synced;
    }
    // Re-probe when the project set changes — a project added, deleted or
    // repointed at another checkout. Compared by identity and count rather than
    // deeply: the controller hands out a fresh unmodifiable list on every save,
    // so this fires exactly when something was actually written.
    if (!identical(oldWidget.projects, widget.projects)) _rescan();
  }

  /// The mounted entry point: shows the scanning state, then scans.
  ///
  /// Split from [_scan] because `initState` also needs to start one, and asking
  /// for a rebuild from there — before the first frame exists — is an error.
  void _rescan() {
    setState(() => _scanning = widget.projects.isNotEmpty);
    _scan();
  }

  /// Probes every project's repository.
  ///
  /// Kicked from `initState` and from a project change rather than from
  /// `build`, because it does real disk IO — the same rule that keeps
  /// `recoverOrphans` out of `initialize`, for the same reason: a scan running
  /// inside a build is a scan running inside every widget test.
  Future<void> _scan() async {
    final List<Project> projects = widget.projects;
    if (projects.isEmpty) {
      _statuses = const <String, ProjectContextStatus>{};
      return;
    }
    _scanning = true;

    final Map<String, ProjectContextStatus> next =
        <String, ProjectContextStatus>{};
    for (final Project project in projects) {
      next[project.id] = await _probe.probe(project);
    }

    if (!mounted) return;
    setState(() {
      _statuses = next;
      _scanning = false;
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final String value = _field.text.trim();
    setState(() => _synced = value);
    await widget.controller.setEnrichmentInstructions(value);
  }

  void _revert() {
    setState(() {
      _synced = _stored;
      _field.text = _synced;
    });
  }

  /// Throw away the user's text and adopt the shipped default again.
  ///
  /// `_synced` is set from the controller *after* the write, not from the
  /// constant, so the field agrees with whatever settings actually resolved to.
  Future<void> _restoreDefault() async {
    await widget.controller.resetEnrichmentInstructions();
    if (!mounted) return;
    setState(() {
      _synced = _stored;
      _field.text = _synced;
    });
  }

  /// One project, and what its repository currently contributes.
  ///
  /// Uses [InfoRow] so it reads as the same kind of fact as the endpoint and
  /// storage rows above — this is a report, not a control.
  Widget _projectRow(Project project) {
    final ProjectContextStatus? status = _statuses[project.id];
    return InfoRow(
      label: project.name.toUpperCase(),
      value: status?.summary ?? 'checking…',
      monospace: true,
      valueColor: status == null
          ? Console.dim
          : (status.needsAttention ? Console.amber : Console.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int length = _field.text.trim().length;
    final bool overLimit = length > EnrichmentContext.maxProfileChars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SectionHeader(title: 'ENRICHMENT CONTEXT'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Who you are and what you collect. Sent with every '
                      'capture so titles, categories and tags match how you '
                      'actually file things.',
                      style: TextStyle(
                        color: Console.mutedSoft,
                        fontSize: 10,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Which of the two is on screen. Without it a default that
                  // reads like someone's own words is indistinguishable from
                  // text the user wrote and forgot.
                  Text(
                    widget.controller.hasCustomEnrichmentInstructions
                        ? 'CUSTOM'
                        : 'DEFAULT',
                    style: ConsoleText.micro.copyWith(
                      color: widget.controller.hasCustomEnrichmentInstructions
                          ? Console.cyan
                          : Console.dim,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConsoleField(
                controller: _field,
                focusNode: _focus,
                minLines: 5,
                maxLines: 12,
                fontSize: 12,
                hintText:
                    'e.g. I build offline-first Flutter apps and run a small '
                    'consultancy. I capture product ideas, meeting notes and '
                    'specs for coding agents. File anything with a repo name '
                    'in it as an agent task.',
                // Rebuilds the counter and the UNSAVED marker as the user
                // types; the value itself is not written until blur.
                onChanged: (String _) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Text(
                    '$length / ${EnrichmentContext.maxProfileChars}',
                    style: ConsoleText.micro.copyWith(
                      color: overLimit ? Console.amber : Console.dim,
                    ),
                  ),
                  if (overLimit) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      'TRUNCATED WHEN SENT',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                  ],
                  const Spacer(),
                  if (_dirty) ...<Widget>[
                    Text(
                      'UNSAVED',
                      style: ConsoleText.micro.copyWith(color: Console.amber),
                    ),
                    const SizedBox(width: 10),
                    TextButton(onPressed: _revert, child: const Text('REVERT')),
                    TextButton(onPressed: _commit, child: const Text('SAVE')),
                  ] else
                    TextButton.icon(
                      // Disabled while the default is already in force, like
                      // the audio card's own restore button.
                      onPressed: widget.controller.hasCustomEnrichmentInstructions
                          ? _restoreDefault
                          : null,
                      icon: const Icon(Icons.restart_alt, size: 15),
                      label: const Text('RESTORE DEFAULT'),
                    ),
                ],
              ),
              const Divider(color: Console.border, height: 26),
              Row(
                children: <Widget>[
                  Text(
                    'PROJECT CONTEXT',
                    style: ConsoleText.micro.copyWith(
                      color: Console.muted,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                    ),
                  ),
                  const Spacer(),
                  if (_scanning)
                    Text(
                      'SCANNING…',
                      style: ConsoleText.micro.copyWith(color: Console.cyan),
                    )
                  else if (widget.projects.isNotEmpty)
                    TextButton.icon(
                      onPressed: _rescan,
                      icon: const Icon(Icons.refresh, size: 15),
                      label: const Text('RESCAN'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'A capture filed under a project also carries that project\'s '
                'own description. The first of '
                '${ProjectContextReader.defaultCandidates.take(3).join(", ")} '
                'found in its repository is used, so the repo stays the source '
                'of truth and the context updates itself. Read once per '
                'capture, so an edit to the file applies immediately.',
                style: const TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              if (widget.projects.isEmpty)
                Text(
                  'No projects yet — captures carry the profile above only.',
                  style: ConsoleText.micro.copyWith(color: Console.dim),
                )
              else
                ...widget.projects.map(_projectRow),
            ],
          ),
        ),
      ],
    );
  }
}

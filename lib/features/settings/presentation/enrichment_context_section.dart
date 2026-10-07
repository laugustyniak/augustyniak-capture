import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../enrichment/data/soul_reader.dart';
import '../../enrichment/domain/enrichment_context.dart';
import '../../projects/data/directory_picker.dart';
import '../../projects/data/project_context_probe.dart';
import '../../projects/data/project_context_reader.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/related_captures.dart';
import '../../recordings/domain/stale_rank.dart';
import '../../recordings/presentation/recordings_controller.dart';
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
    this.picker = const FilePickerDirectoryPicker(),
    this.soulReader = const SoulReader(),
    this.recordings,
  });

  /// Counts and runs the re-rank of captures ranked under an older soul. Null
  /// hides the row — every test that hosts this section bare, and any host
  /// with no queue to re-rank.
  final RecordingsController? recordings;

  final SettingsController controller;

  /// Chooses the folder `SOUL.md` lives in. The same desktop-only seam as the
  /// vault's: a widget test injects a fake, and mobile keeps the typed path.
  final DirectoryPicker picker;

  /// Reads the soul for the status line — the same reader enrichment uses, so
  /// the line reports exactly what the next capture will be sent.
  final SoulReader soulReader;

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

  late final TextEditingController _soulField = TextEditingController(
    text: _storedSoulPath,
  );
  final FocusNode _soulFocus = FocusNode();
  late String _syncedSoulPath = _storedSoulPath;

  /// What the soul file resolves to right now. Null while unset or while the
  /// check runs, and only ever probed with a path configured — which is what
  /// keeps every existing Config test off the filesystem.
  ResolvedSoul? _soul;
  String? _pickerError;

  /// Captures on the desk ranked under an older soul. Null until counted.
  int? _staleCount;

  /// Recounted after anything that can change the current soul or the ranks:
  /// a path change, a profile save, a finished re-rank. Never from `build` —
  /// resolving the soul reads the disk.
  Future<void> _refreshStale() async {
    final RecordingsController? recordings = widget.recordings;
    if (recordings == null) return;
    final int count = await recordings.staleRankCount();
    if (!mounted) return;
    setState(() => _staleCount = count);
  }

  Future<void> _rerank() async {
    final RecordingsController? recordings = widget.recordings;
    if (recordings == null) return;
    await recordings.rerankStale();
    await _refreshStale();
  }

  /// The re-rank row, rebuilt from the controller so its progress moves while
  /// the rest of the section stays still.
  Widget _rerankRow(RecordingsController recordings) {
    return ListenableBuilder(
      listenable: recordings,
      builder: (BuildContext context, Widget? _) {
        final RerankProgress? progress = recordings.rerankProgress;
        if (progress != null) {
          return Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'RE-RANKING ${progress.done} / ${progress.total}',
                  style: ConsoleText.micro.copyWith(color: Console.accent),
                ),
              ),
              TextButton(
                onPressed: recordings.cancelRerank,
                child: const Text('CANCEL'),
              ),
            ],
          );
        }
        final int count = _staleCount ?? 0;
        if (count == 0) return const SizedBox.shrink();
        return Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '$count ranked under an older soul · one model call each',
                style: ConsoleText.micro.copyWith(color: Console.amber),
              ),
            ),
            TextButton(
              onPressed: _rerank,
              child: Text('RE-RANK $count'),
            ),
          ],
        );
      },
    );
  }

  late final TextEditingController _embeddingField = TextEditingController(
    text: widget.controller.embeddingModel ?? '',
  );
  final FocusNode _embeddingFocus = FocusNode();

  Future<void> _commitEmbeddingModel() async {
    await widget.controller.setEmbeddingModel(_embeddingField.text);
    if (mounted) setState(() {});
  }

  /// The RELATED CAPTURES block: the model, then what the index holds and the
  /// build that fills it — rebuilt from the controller so progress moves.
  Widget _relatedBlock() {
    final RecordingsController? recordings = widget.recordings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('RELATED CAPTURES · EMBEDDING MODEL', style: ConsoleText.fieldLabel),
        const SizedBox(height: 6),
        ConsoleField(
          controller: _embeddingField,
          focusNode: _embeddingFocus,
          monospace: true,
          fontSize: 12,
          textInputAction: TextInputAction.done,
          onSubmitted: (String _) => _commitEmbeddingModel(),
          hintText: 'text-embedding-3-small · nomic-embed-text',
        ),
        const SizedBox(height: 6),
        if (recordings == null)
          const SizedBox.shrink()
        else
          ListenableBuilder(
            listenable: recordings,
            builder: (BuildContext context, Widget? _) =>
                _indexRow(recordings),
          ),
      ],
    );
  }

  Widget _indexRow(RecordingsController recordings) {
    final IndexProgress? progress = recordings.indexProgress;
    if (progress != null) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'INDEXING ${progress.done} / ${progress.total}',
              style: ConsoleText.micro.copyWith(color: Console.accent),
            ),
          ),
          TextButton(
            onPressed: recordings.cancelIndex,
            child: const Text('CANCEL'),
          ),
        ],
      );
    }
    if (widget.controller.embeddingModel == null) {
      return Text(
        'Off. Name an embedding model served by the enrichment endpoint to '
        'see related captures and repeats.',
        style: ConsoleText.micro.copyWith(color: Console.mutedSoft),
      );
    }
    if (!recordings.relatedEnabled) {
      return Text(
        'Needs an active enrichment profile whose endpoint ends in '
        '/chat/completions.',
        style: ConsoleText.micro.copyWith(color: Console.amber),
      );
    }
    final int count = recordings.unindexedIds().length;
    if (count == 0) {
      return Text(
        'Every capture is indexed. New ones are indexed as they finish.',
        style: ConsoleText.micro.copyWith(color: Console.accent),
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '$count not indexed · one embedding call each',
            style: ConsoleText.micro.copyWith(color: Console.amber),
          ),
        ),
        TextButton(
          key: const ValueKey<String>('build-index'),
          onPressed: recordings.buildIndex,
          child: Text('BUILD INDEX $count'),
        ),
      ],
    );
  }

  String get _storedSoulPath => widget.controller.soulPath ?? '';
  bool get _soulDirty => _soulField.text.trim() != _syncedSoulPath.trim();

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
    _soulFocus.addListener(() {
      if (!_soulFocus.hasFocus && _soulDirty) _commitSoulPath();
    });
    _embeddingFocus.addListener(() {
      if (!_embeddingFocus.hasFocus) _commitEmbeddingModel();
    });
    _probeSoul();
    _refreshStale();
  }

  /// Kicked from `initState` and after a path change, never from `build`: it
  /// reads the disk, the same rule as the project scan below.
  Future<void> _probeSoul() async {
    final String path = _syncedSoulPath.trim();
    if (path.isEmpty) {
      if (_soul != null && mounted) setState(() => _soul = null);
      return;
    }
    final ResolvedSoul soul = await widget.soulReader.resolve(
      path: path,
      typed: _stored,
    );
    if (!mounted || path != _syncedSoulPath.trim()) return;
    setState(() => _soul = soul);
  }

  Future<void> _commitSoulPath() async {
    final String value = _soulField.text.trim();
    setState(() {
      _syncedSoulPath = value;
      _soul = null;
    });
    await widget.controller.setSoulPath(value);
    await _probeSoul();
    await _refreshStale();
  }

  /// Picks the folder and names `SOUL.md` in it: the seam chooses directories,
  /// and one fixed file name is also what keeps the file findable later.
  Future<void> _browseSoul() async {
    setState(() => _pickerError = null);
    try {
      final String current = _syncedSoulPath.trim();
      final String? folder = await widget.picker.pick(
        initialDirectory: current.isEmpty ? null : File(current).parent.path,
      );
      if (folder == null || !mounted) return;
      _soulField.text =
          '$folder${Platform.pathSeparator}${SoulReader.defaultFileName}';
      await _commitSoulPath();
    } catch (exception) {
      if (!mounted) return;
      setState(() => _pickerError = exception.toString());
    }
  }

  /// The line under the path: what the next capture will actually be sent.
  Widget _soulStatus() {
    final ResolvedSoul? soul = _soul;
    final String? error = _pickerError;
    final (String text, Color color) = switch (soul) {
      _ when error != null => ('Browse failed: $error', Console.amber),
      null when _syncedSoulPath.trim().isEmpty => (
        'Optional. A markdown file you edit anywhere — it replaces the '
            'profile below and is re-read for every capture.',
        Console.mutedSoft,
      ),
      null => ('Checking…', Console.dimText),
      ResolvedSoul(origin: SoulOrigin.file) => (
        'USING ${soul.fileName} · ${soul.text.trim().length} chars'
            '${soul.truncated ? ' · TRUNCATED WHEN SENT' : ''}',
        soul.truncated ? Console.amber : Console.accent,
      ),
      ResolvedSoul() => (
        '${soul.fileName} ${soul.origin.name.toUpperCase()} — '
            'USING THE PROFILE BELOW',
        Console.amber,
      ),
    };
    return Text(text, style: ConsoleText.micro.copyWith(color: color));
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
    if (_storedSoulPath != _syncedSoulPath && !_soulDirty) {
      _syncedSoulPath = _storedSoulPath;
      _soulField.text = _syncedSoulPath;
      _probeSoul();
    }
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
    _soulFocus.dispose();
    _soulField.dispose();
    _embeddingFocus.dispose();
    _embeddingField.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final String value = _field.text.trim();
    setState(() => _synced = value);
    await widget.controller.setEnrichmentInstructions(value);
    await _refreshStale();
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
    await _refreshStale();
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
          ? Console.dimText
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
        SectionHeader(title: 'ENRICHMENT CONTEXT'),
        const SizedBox(height: 12),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Your soul: who you are, what you collect, your goals '
                      'and your priority rules. Sent with every capture so '
                      'titles, categories, tags and priority match how you '
                      'actually work.',
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
                          ? Console.accent
                          : Console.dimText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('SOUL FILE', style: ConsoleText.fieldLabel),
              const SizedBox(height: 6),
              ConsoleField(
                controller: _soulField,
                focusNode: _soulFocus,
                monospace: true,
                fontSize: 12,
                textInputAction: TextInputAction.done,
                onSubmitted: (String _) => _commitSoulPath(),
                onChanged: (String _) => setState(() {}),
                hintText: '/Users/you/Notes/SOUL.md',
                suffixIcon: widget.picker.isAvailable
                    ? IconButton(
                        onPressed: _browseSoul,
                        icon: const Icon(Icons.folder_open, size: 18),
                        tooltip: 'Choose the folder holding SOUL.md',
                        color: Console.muted,
                      )
                    : null,
              ),
              const SizedBox(height: 6),
              _soulStatus(),
              if (widget.recordings case final RecordingsController r)
                _rerankRow(r),
              const SizedBox(height: 12),
              Text(
                _soul?.origin == SoulOrigin.file
                    ? 'PROFILE · FALLBACK'
                    : 'PROFILE',
                style: ConsoleText.fieldLabel,
              ),
              const SizedBox(height: 6),
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
                    'in it as an agent task. p0 is a client waiting; p3 is '
                    'anything off my current goals.',
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
                      color: overLimit ? Console.amber : Console.dimText,
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
                      onPressed:
                          widget.controller.hasCustomEnrichmentInstructions
                          ? _restoreDefault
                          : null,
                      icon: const Icon(Icons.restart_alt, size: 15),
                      label: const Text('RESTORE DEFAULT'),
                    ),
                ],
              ),
              Divider(color: Console.border, height: 26),
              // Off by default: one extra model call per dictation is a cost
              // the user opts into, and the proposal still waits for ACCEPT.
              // A Row, not a SwitchListTile: a ListTile inside this card's
              // decorated box trips the "ink splashes may be invisible" check.
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'PROPOSE A CLEAN-UP FOR EVERY DICTATION',
                          style: ConsoleText.micro.copyWith(
                            color: Console.muted,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .6,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Fillers out, misheard names fixed against your '
                          'soul. One extra model call each; nothing replaces '
                          'the transcript until you accept it.',
                          style: TextStyle(
                            color: Console.mutedSoft,
                            fontSize: 10,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Switch(
                    key: const ValueKey<String>('auto-cleanup'),
                    value: widget.controller.autoCleanup,
                    onChanged: (bool value) async {
                      await widget.controller.setAutoCleanup(value);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
              Divider(color: Console.border, height: 26),
              _relatedBlock(),
              Divider(color: Console.border, height: 26),
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
                      style: ConsoleText.micro.copyWith(color: Console.accent),
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
                style: TextStyle(
                  color: Console.mutedSoft,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              if (widget.projects.isEmpty)
                Text(
                  'No projects yet — captures carry the profile above only.',
                  style: ConsoleText.micro.copyWith(color: Console.dimText),
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

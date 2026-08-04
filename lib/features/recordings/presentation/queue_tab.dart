import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_controller.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import 'queue_metrics.dart';
import 'recording_card.dart';
import 'recording_editor.dart';
import 'recordings_controller.dart';

/// The five buckets from the design. They **partition** the queue: every item
/// matches exactly one of `queue`/`ready`/`failed`/`raw`, and `all` is their
/// union — which is what lets each chip carry a count that adds up.
enum RecordingFilter { all, queue, ready, failed, raw }

/// The original Phase-1 screen: header, review progress, search, status filters
/// and the capture list. Owns only view state; every mutation goes through
/// [RecordingsController].
class QueueTab extends StatefulWidget {
  const QueueTab({super.key, required this.controller, this.projects});

  final RecordingsController controller;
  final ProjectsController? projects;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.all;
  String searchQuery = '';
  String? projectFilterId;
  final TextEditingController searchController = TextEditingController();

  /// The row currently in edit mode, if any.
  ///
  /// Kept here rather than inside the row because the controller notifies on
  /// every pipeline tick — a flag living in the card would survive that, but a
  /// card scrolled out of the list would not, and the mode would silently end.
  /// One id also enforces the rule that only one row is editable at a time,
  /// which keeps "where is my keyboard focus" answerable.
  String? editingId;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RecordingsController controller = widget.controller;
    final List<Recording> all = controller.recordings;
    final List<Project> projects =
        widget.projects?.projects ?? const <Project>[];
    final String? effectiveProjectFilterId =
        projects.any((Project project) => project.id == projectFilterId)
        ? projectFilterId
        : null;
    final List<Recording> visible = _filter(all, effectiveProjectFilterId);
    final int reviewedCount = all
        .where((Recording item) => item.isProcessedByUser)
        .length;

    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: ConsoleHeader(
              title: 'Queue',
              trailing:
                  '${all.length} ${all.length == 1 ? 'capture' : 'captures'}',
            ),
          ),
          if (controller.error != null) ...<Widget>[
            const SizedBox(height: 10),
            ErrorBanner(message: controller.error!),
          ],
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 190),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ReviewedStrip(
                    total: all.length,
                    reviewed: reviewedCount,
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SearchField(
                    controller: searchController,
                    value: searchQuery,
                    onChanged: (String value) {
                      setState(() => searchQuery = value);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                if (projects.isNotEmpty) ...<Widget>[
                  _ProjectFilter(
                    projects: projects,
                    selectedId: effectiveProjectFilterId,
                    onChanged: (String? value) {
                      setState(() => projectFilterId = value);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                _FilterRow(
                  selected: selectedFilter,
                  // Counted before the search is applied: the chips describe
                  // the queue, not the current query — otherwise every count
                  // would collapse to whatever the user last typed.
                  counts: <RecordingFilter, int>{
                    for (final RecordingFilter filter in RecordingFilter.values)
                      filter: all
                          .where((Recording item) => _matches(filter, item))
                          .length,
                  },
                  onSelected: (RecordingFilter value) {
                    setState(() => selectedFilter = value);
                  },
                ),
                const SizedBox(height: 14),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: EmptyPanel(
                      icon: Icons.graphic_eq,
                      title: _emptyLabel(selectedFilter),
                      blurb:
                          'Every capture is written to disk and verified '
                          'before processing is even attempted.',
                    ),
                  )
                else
                  ...visible.map(
                    (Recording recording) => Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      // The row grows into the editor in place. Animating the
                      // height is what keeps the rows below from jumping — the
                      // edited item has to stay under the finger that opened it.
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: recording.id == editingId
                            ? _buildEditor(recording)
                            : _buildCard(recording),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Recording> _filter(
    List<Recording> recordings,
    String? effectiveProjectFilterId,
  ) {
    final List<Recording> byStatus = recordings
        .where(
          (Recording item) =>
              _matches(selectedFilter, item) &&
              (effectiveProjectFilterId == null ||
                  item.projectId == effectiveProjectFilterId),
        )
        .toList();
    final String query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return byStatus;
    }
    return byStatus.where((Recording item) {
      final String haystack = <String?>[
        item.transcript,
        item.title,
        ...item.tags,
        item.filePath.split(Platform.pathSeparator).last,
        item.id,
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  Widget _buildCard(Recording recording) {
    final RecordingsController controller = widget.controller;
    return RecordingCard(
      recording: recording,
      isPlaying: controller.playingId == recording.id,
      // View-only: the enrichment stage has no persisted status, so this comes
      // off the controller's in-flight set rather than off the item.
      isEnriching: controller.isEnriching(recording.id),
      projectName: _projectName(recording.projectId),
      onTogglePlay: () => controller.togglePlayback(recording.id),
      onOpen: () => controller.openSource(recording.id),
      onRetry: () => controller.retryTranscription(recording.id),
      onEdit: () => setState(() => editingId = recording.id),
      onToggleProcessed: () async {
        // Fire-and-forget: the haptic is cosmetic and must not gate a durable
        // state write. Awaiting it means the review flag waits on the platform
        // answering — which, on a host that never does, is forever.
        unawaited(HapticFeedback.selectionClick());
        await controller.toggleProcessed(recording.id);
      },
    );
  }

  /// The same row, in edit mode.
  ///
  /// Every callback is fire-and-forget on purpose: each one persists on its
  /// own and the controller notifies when it lands, so awaiting here would only
  /// hold a keystroke behind a disk write. The keyed subtree is what makes the
  /// editor's own state (its text controllers, its dirty flags) belong to *this
  /// item* — without it, editing one row and then another would inherit the
  /// first row's fields.
  Widget _buildEditor(Recording recording) {
    final RecordingsController controller = widget.controller;
    return RecordingEditor(
      key: ValueKey<String>('editor-${recording.id}'),
      recording: recording,
      revisions: controller.revisionsFor(recording.id),
      tagSuggestions: _tagSuggestions(recording),
      projects: widget.projects?.projects ?? const <Project>[],
      onTitleChanged: (String value) =>
          controller.setTitle(recording.id, value),
      onTextChanged: (String value) =>
          controller.editTranscript(recording.id, value),
      onCategoryChanged: (CaptureCategory? value) =>
          controller.setCategory(recording.id, value),
      onTagsChanged: (List<String> values) =>
          controller.setTags(recording.id, values),
      onProjectChanged: (String? value) =>
          controller.setProject(recording.id, value),
      onDelete: () => _confirmDelete(recording),
      onDone: () => setState(() => editingId = null),
    );
  }

  /// The one irreversible action in the queue, so it is the one that asks.
  ///
  /// Awaited rather than fired and forgotten, unlike every other editor
  /// callback: those each persist one field and the controller notifies when it
  /// lands, while this one has to leave edit mode *after* the row is gone —
  /// clearing `editingId` first would flash the read-only card for a frame
  /// before it disappears, and clearing it never would leave the tab holding the
  /// id of an item that no longer exists.
  Future<void> _confirmDelete(Recording recording) async {
    final String name = (recording.title ?? '').trim().isEmpty
        ? File(recording.filePath).uri.pathSegments.last
        : recording.title!.trim();
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Delete this capture?',
      message:
          '"$name" and its source file are removed from disk. The text, tags '
          'and category go with it. This cannot be undone.',
      confirmLabel: 'DELETE',
    );
    if (!confirmed || !mounted) return;
    await widget.controller.deleteRecording(recording.id);
    if (!mounted) return;
    setState(() => editingId = null);
  }

  /// The vocabulary already in use elsewhere, most-used first, excluding this
  /// item's own tags. Offered as one-tap chips so tagging converges on a set of
  /// words instead of accumulating near-duplicates.
  List<String> _tagSuggestions(Recording current) {
    final Map<String, int> uses = <String, int>{};
    for (final Recording item in widget.controller.recordings) {
      if (item.id == current.id) continue;
      for (final String tag in item.tags) {
        uses[tag] = (uses[tag] ?? 0) + 1;
      }
    }
    final List<String> values = uses.keys.toList()
      ..sort((String a, String b) => uses[b]!.compareTo(uses[a]!));
    return values;
  }

  String? _projectName(String? id) {
    if (id == null) return null;
    for (final Project project
        in widget.projects?.projects ?? const <Project>[]) {
      if (project.id == id) return project.name;
    }
    return 'Missing project';
  }
}

class _ProjectFilter extends StatelessWidget {
  const _ProjectFilter({
    required this.projects,
    required this.selectedId,
    required this.onChanged,
  });

  final List<Project> projects;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String?>(
      // FormField owns its selected value internally. Recreate that state when
      // the controlled selection or project vocabulary changes; otherwise a
      // deleted project can remain as a dangling Dropdown value for one frame.
      key: ValueKey<String>(
        'project-filter:${selectedId ?? 'all'}:'
        '${projects.map((Project project) => project.id).join(',')}',
      ),
      initialValue: selectedId,
      dropdownColor: Console.surfaceRaised,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.account_tree_outlined, size: 18),
        labelText: 'Project',
      ),
      items: <DropdownMenuItem<String?>>[
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('All projects'),
        ),
        for (final Project project in projects)
          DropdownMenuItem<String?>(
            value: project.id,
            child: Text(project.name),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// Single definition of what each bucket contains — used both to filter the
/// list and to count the chips, so the two can never disagree.
bool _matches(RecordingFilter filter, Recording item) => switch (filter) {
  RecordingFilter.all => true,
  RecordingFilter.queue =>
    item.status == RecordingStatus.pendingTranscription ||
        item.status == RecordingStatus.transcribing,
  RecordingFilter.ready => item.status == RecordingStatus.completed,
  RecordingFilter.failed => item.status == RecordingStatus.failed,
  // Persisted and verified, but not handed to a processor yet.
  RecordingFilter.raw => item.status == RecordingStatus.saved,
};

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.value,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    const OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
      borderSide: BorderSide(color: Console.border),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: Console.text, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        hintText: 'Search captures',
        hintStyle: const TextStyle(color: Console.dim, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Console.dim, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 42),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: Console.dim, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: Console.surface,
        border: border,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Console.borderStrong),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  final RecordingFilter selected;
  final Map<RecordingFilter, int> counts;
  final ValueChanged<RecordingFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: RecordingFilter.values.map((RecordingFilter item) {
          return Padding(
            padding: const EdgeInsets.only(right: 7),
            child: ConsoleChip(
              label: item.name.toUpperCase(),
              count: counts[item] ?? 0,
              selected: item == selected,
              onSelected: () => onSelected(item),
            ),
          );
        }).toList(),
      ),
    );
  }
}

String _emptyLabel(RecordingFilter filter) => switch (filter) {
  RecordingFilter.all => 'Nothing captured yet.',
  RecordingFilter.queue => 'The processing queue is empty.',
  RecordingFilter.ready => 'No finished output yet.',
  RecordingFilter.failed => 'No failed jobs.',
  RecordingFilter.raw => 'Nothing waiting to be queued.',
};

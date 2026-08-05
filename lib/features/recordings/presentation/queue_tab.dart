import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_controller.dart';
import '../domain/agent_artifact.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import 'agent_artifact_viewer_modal.dart';
import 'card_parts.dart';
import 'compact_queue_header.dart';
import 'handoff_sheet.dart';
import 'queue_metrics.dart';
import 'recording_card.dart';
import 'recording_editor.dart';
import 'recording_row.dart';
import 'recordings_controller.dart';

/// The five buckets from the design. They **partition** the queue: every item
/// matches exactly one of `queue`/`ready`/`failed`/`raw`, and `all` is their
/// union — which is what lets each chip carry a count that adds up.
enum RecordingFilter { all, queue, ready, failed, raw }

/// The *review* axis — deliberately not a sixth [RecordingFilter].
///
/// `Recording` carries two independent state axes: where the pipeline has got
/// to, and whether the user has dealt with the item. [RecordingFilter] covers
/// the first and partitions it; folding "have I dealt with this" into that row
/// would break the arithmetic that lets every chip's count add up, and would
/// claim a relationship between the two that does not exist. So they are two
/// rows that compose by intersection.
///
/// It exists because the header already promoted `CLEAR 27 / 28` to the
/// biggest number on the screen while offering no way to act on it: the queue
/// held every capture ever taken, and ticking one off changed a progress bar
/// and nothing else. [desk] is the default for that reason — it is what turns
/// the review toggle from decoration into the control that empties the list.
///
/// The names are the delegation vocabulary, not mail: a capture sits on the
/// user's [desk] until they decide who executes it, and leaves as [handedOff].
/// An inbox is what the world puts on you; this queue only ever holds your own
/// thoughts, so the arrow points the other way.
enum ReviewFilter { desk, handedOff, all }

/// The original Phase-1 screen: header, review progress, search, status filters
/// and the capture list. Owns only view state; every mutation goes through
/// [RecordingsController].
class QueueTab extends StatefulWidget {
  const QueueTab({
    super.key,
    required this.controller,
    this.projects,
    this.initialProjectId,
  });

  final RecordingsController controller;
  final ProjectsController? projects;
  final String? initialProjectId;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.all;
  ReviewFilter reviewFilter = ReviewFilter.desk;
  String searchQuery = '';
  String? projectFilterId;
  final TextEditingController searchController = TextEditingController();

  /// The one compact row currently opened for reading.
  String? expandedId;

  /// The row currently in edit mode, if any.
  ///
  /// Kept here rather than inside the row because the controller notifies on
  /// every pipeline tick — a flag living in the card would survive that, but a
  /// card scrolled out of the list would not, and the mode would silently end.
  /// One id also enforces the rule that only one row is editable at a time,
  /// which keeps "where is my keyboard focus" answerable.
  ///
  /// It is also read by [_filter], which exempts this row from every filter for
  /// the reason stated there.
  String? editingId;

  /// The row the keyboard is on, if any. Null means "no row selected", which is
  /// the state the tab opens in — a selection the user did not ask for would
  /// make the first arrow press act on an arbitrary capture.
  ///
  /// An id rather than an index, for the same reason [editingId] is: the list
  /// re-sorts and re-filters under the user, and an index would silently move
  /// the selection onto whatever item slid into that slot.
  String? focusedId;

  /// Whether the compact header's two panels are open *by the user's hand*.
  ///
  /// Not the whole answer: a panel whose control is engaged is forced open
  /// regardless, so a query or a status filter can never be the invisible reason
  /// the list is short. See [CompactQueueHeader]. Both are ignored in the wide
  /// forms, where the controls are always on screen.
  bool searchPanelOpen = false;
  bool filterPanelOpen = false;

  final FocusNode searchFocus = FocusNode();

  /// Owns the arrow keys and the single-letter actions. It sits above the list
  /// rather than on each row so the shortcuts work before anything is selected,
  /// and so the row widgets stay free of key handling.
  final FocusNode listFocus = FocusNode(debugLabel: 'queue-shortcuts');

  @override
  void initState() {
    super.initState();
    projectFilterId = widget.initialProjectId;
  }

  @override
  void didUpdateWidget(QueueTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProjectId != oldWidget.initialProjectId) {
      setState(() {
        projectFilterId = widget.initialProjectId;
      });
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocus.dispose();
    listFocus.dispose();
    super.dispose();
  }

  /// Moves the selection by [delta] through what is currently *visible*, so
  /// arrowing never lands on a row the active filters exclude.
  void _moveFocus(List<Recording> visible, int delta) {
    if (visible.isEmpty) return;
    final int current = visible.indexWhere(
      (Recording item) => item.id == focusedId,
    );
    // No selection yet: the first press takes the end the user is moving
    // towards rather than jumping to the middle of the list.
    final int next = current < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : (current + delta).clamp(0, visible.length - 1);
    setState(() => focusedId = visible[next].id);
  }

  /// Runs [action] against the selected row, if there is one. Every shortcut
  /// goes through here so a key press with nothing selected is a no-op rather
  /// than an action on a guessed item.
  void _onFocused(List<Recording> visible, void Function(Recording) action) {
    final String? id = focusedId;
    if (id == null) return;
    for (final Recording item in visible) {
      if (item.id == id) {
        action(item);
        return;
      }
    }
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
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < Console.compactBreakpoint;
        // Counted before the search is applied: the chips describe the queue,
        // not the current query — otherwise every count would collapse to
        // whatever the user last typed.
        final Map<RecordingFilter, int> counts = <RecordingFilter, int>{
          for (final RecordingFilter filter in RecordingFilter.values)
            filter: all
                .where((Recording item) => _matches(filter, item))
                .length,
        };
        // A panel the user did not open, but cannot be allowed to miss: with the
        // control off screen its effect on the list is unexplainable.
        final bool searchOpen = searchPanelOpen || searchQuery.isNotEmpty;
        final bool filtersOpen =
            filterPanelOpen ||
            selectedFilter != RecordingFilter.all ||
            effectiveProjectFilterId != null;
        return _QueueShortcuts(
          focusNode: listFocus,
          // Rebuilt with the current `visible` list on every frame, so a shortcut
          // can never act on a row that the filters have since removed.
          onNext: () => _moveFocus(visible, 1),
          onPrevious: () => _moveFocus(visible, -1),
          onEdit: () => _onFocused(visible, (Recording item) {
            setState(() => editingId = item.id);
          }),
          onToggleProcessed: () => _onFocused(
            visible,
            (Recording item) => controller.toggleProcessed(item.id),
          ),
          onTogglePlay: () => _onFocused(
            visible,
            (Recording item) => controller.togglePlayback(item.id),
          ),
          onRoute: () => _onFocused(visible, (Recording item) {
            if (controller.canRoute(item)) controller.route(item.id);
          }),
          onHandoff: () => _onFocused(visible, (Recording item) {
            if (controller.canHandoff(item)) _openHandoff(item);
          }),
          // `Ctrl+F` and `/` have to reveal the box before they can focus it —
          // on a phone it is behind the header's search button.
          onSearch: () {
            setState(() => searchPanelOpen = true);
            searchFocus.requestFocus();
          },
          onClearFocus: () => setState(() => focusedId = null),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                // No page title on a phone. It is the one screen that can spare
                // none: the header, the progress strip and the always-open
                // controls took roughly a third of a 393x852 device before the
                // first capture was drawn, and Queue is the tab the app opens
                // on. The four other tabs keep theirs — they are destinations
                // the user navigated to, and each needs to say what it is.
                if (!compact)
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
                // Pinned above the scroll area, not scrolled with it.
                //
                // These four are the screen's entire navigation, and as list children
                // they left the screen on the first drag. The consequence is worse
                // than the inconvenience: with the chips off-screen, "empty because a
                // filter excludes everything" and "empty because there is nothing"
                // become the same picture, and the user has no way to tell which one
                // they are looking at without scrolling back up to check.
                if (compact)
                  CompactQueueHeader(
                    total: all.length,
                    reviewed: reviewedCount,
                    filter: reviewFilter,
                    onFilterChanged: (ReviewFilter value) {
                      setState(() => reviewFilter = value);
                    },
                    searchOpen: searchOpen,
                    // Toggles the user's own flag, never the resolved one: a
                    // panel forced open by a live filter must stay open, and
                    // folding the two together would also make "clear the
                    // filter" close the panel out from under the finger that
                    // cleared it.
                    onToggleSearch: () {
                      setState(() => searchPanelOpen = !searchPanelOpen);
                      if (searchPanelOpen) searchFocus.requestFocus();
                    },
                    search: _SearchField(
                      controller: searchController,
                      focusNode: searchFocus,
                      value: searchQuery,
                      onChanged: (String value) {
                        setState(() => searchQuery = value);
                      },
                    ),
                    filtersOpen: filtersOpen,
                    onToggleFilters: () {
                      setState(() => filterPanelOpen = !filterPanelOpen);
                    },
                    filters: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (projects.isNotEmpty) ...<Widget>[
                          _ProjectFilter(
                            projects: projects,
                            selectedId: effectiveProjectFilterId,
                            onChanged: (String? value) {
                              setState(() => projectFilterId = value);
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                        _FilterRow(
                          selected: selectedFilter,
                          counts: counts,
                          onSelected: (RecordingFilter value) {
                            setState(() => selectedFilter = value);
                          },
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: Column(
                      children: <Widget>[
                        ReviewedStrip(
                          total: all.length,
                          reviewed: reviewedCount,
                          filter: reviewFilter,
                          onFilterChanged: (ReviewFilter value) {
                            setState(() => reviewFilter = value);
                          },
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _QueueControls(
                            searchController: searchController,
                            searchFocusNode: searchFocus,
                            searchQuery: searchQuery,
                            onSearchChanged: (String value) {
                              setState(() => searchQuery = value);
                            },
                            projects: projects,
                            selectedProjectId: effectiveProjectFilterId,
                            onProjectChanged: (String? value) {
                              setState(() => projectFilterId = value);
                            },
                            selectedFilter: selectedFilter,
                            counts: counts,
                            onFilterSelected: (RecordingFilter value) {
                              setState(() => selectedFilter = value);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    // Tighter on a phone, and starting closer to the header:
                    // the compact row draws its own margin and its own border,
                    // so a wide gutter here only shrinks the one column of text
                    // the screen exists to show.
                    padding: compact
                        ? const EdgeInsets.fromLTRB(10, 6, 10, 24)
                        : const EdgeInsets.fromLTRB(16, 14, 16, 190),
                    children: <Widget>[
                      if (visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: EmptyPanel(
                            // An empty list has two very different causes and they
                            // look identical: nothing was captured, or a filter is
                            // hiding what was. Naming the filter that emptied the
                            // list is the whole difference between "you are done"
                            // and "you cannot see your work".
                            icon: all.isEmpty
                                ? Icons.graphic_eq
                                : Icons.inbox_outlined,
                            title: _emptyLabel(
                              selectedFilter,
                              reviewFilter,
                              hasAny: all.isNotEmpty,
                            ),
                            blurb: all.isEmpty
                                ? 'Every capture is written to disk and verified '
                                      'before processing is even attempted.'
                                : 'Adjust the review, status, project, or search '
                                      'filters to broaden the queue.',
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
                                  : compact
                                  ? _buildMobileRow(recording)
                                  : _buildCard(recording),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The queue narrowed by the status chips, the project selector and the
  /// search box — with one deliberate exemption.
  ///
  /// **The row in edit mode is never filtered away.** A typed-but-uncommitted
  /// value lives only inside [RecordingEditor], which does not write on
  /// disposal, so removing its row would discard the edit with nothing left to
  /// recover it from. Both ways that can happen are ordinary: the user types
  /// into the search box while the title field is dirty, or a background stage
  /// finishes and moves the item into a bucket the active chip excludes. The
  /// exemption covers exactly one row and ends when DONE closes the mode.
  List<Recording> _filter(
    List<Recording> recordings,
    String? effectiveProjectFilterId,
  ) {
    final String query = searchQuery.trim().toLowerCase();
    return recordings.where((Recording item) {
      if (item.id == editingId) return true;
      if (!_matchesReview(reviewFilter, item)) return false;
      if (!_matches(selectedFilter, item)) return false;
      if (effectiveProjectFilterId != null &&
          item.projectId != effectiveProjectFilterId) {
        return false;
      }
      if (query.isEmpty) return true;
      final String haystack = <String?>[
        item.transcript,
        item.title,
        // The model's paraphrase is usually what the user actually remembers
        // about a capture ("the one about the database migration"), and it was
        // the one piece of its own output the search could not see.
        item.summary,
        item.category?.name,
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
      focused: recording.id == focusedId,
      canRoute: controller.canRoute(recording),
      onRoute: () => controller.route(recording.id),
      canHandoff: controller.canHandoff(recording),
      onHandoff: () => _openHandoff(recording),
      onSelectArtifact: (AgentArtifact artifact) {
        showAgentArtifactViewer(
          context,
          controller: controller,
          recording: recording,
          artifact: artifact,
        );
      },
      onTogglePlay: () => controller.togglePlayback(recording.id),
      onOpen: () => controller.openSource(recording.id),
      onRetry: () => controller.retryTranscription(recording.id),
      onEnrich: () => controller.retryEnrichment(recording.id),
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

  /// Narrow layouts use an accordion row, while the desktop path above remains
  /// the full card with its existing keyboard selection and action surface.
  Widget _buildMobileRow(Recording recording) {
    final RecordingsController controller = widget.controller;
    return RecordingRow(
      key: ValueKey<String>('row-${recording.id}'),
      recording: recording,
      expanded: recording.id == expandedId,
      focused: recording.id == focusedId,
      isPlaying: controller.playingId == recording.id,
      isEnriching: controller.isEnriching(recording.id),
      projectName: _projectName(recording.projectId),
      canRoute: controller.canRoute(recording),
      canHandoff: controller.canHandoff(recording),
      onTap: () => setState(() {
        focusedId = recording.id;
        expandedId = recording.id == expandedId ? null : recording.id;
      }),
      onTogglePlay: () => controller.togglePlayback(recording.id),
      onOpen: () => controller.openSource(recording.id),
      onRetry: () => controller.retryTranscription(recording.id),
      onEnrich: () => controller.retryEnrichment(recording.id),
      onEdit: () => setState(() => editingId = recording.id),
      onRoute: () => controller.route(recording.id),
      onHandoff: () => _openHandoff(recording),
      onToggleProcessed: () async {
        unawaited(HapticFeedback.selectionClick());
        await controller.toggleProcessed(recording.id);
      },
    );
  }

  /// The handoff is the one queue action that asks a question before it acts —
  /// which agent, and with what opening line — so it opens a sheet where every
  /// other control here fires on the tap.
  void _openHandoff(Recording recording) {
    showHandoffSheet(
      context,
      controller: widget.controller,
      recording: recording,
      projectName: _projectName(recording.projectId),
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
    // The same name the card shows, so the dialog names the row the user is
    // looking at rather than a filename they have never seen.
    final String name = displayNameFor(recording);
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
    setState(() {
      editingId = null;
      // The selection is an id, and this one no longer resolves — leaving it
      // would point the keyboard layer at a row that is gone.
      if (focusedId == recording.id) focusedId = null;
      if (expandedId == recording.id) expandedId = null;
    });
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

/// Search, project and status filters — one strip, laid out by how much room
/// the queue actually has.
///
/// Wide enough (a desktop window) and the three sit on a single line, which is
/// what keeps the first card near the top of the screen instead of three rows
/// down. Narrower and they stack the way they always did: below
/// [_singleLineWidth] the project selector and the five chips cannot both keep
/// a legible search box beside them, and a search field squeezed to a few
/// characters is worse than a second row.
class _QueueControls extends StatelessWidget {
  const _QueueControls({
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.projects,
    required this.selectedProjectId,
    required this.onProjectChanged,
    required this.selectedFilter,
    required this.counts,
    required this.onFilterSelected,
  });

  /// Below this the strip stacks. Derived from what the row needs rather than
  /// from a device class: the project selector is fixed at
  /// [_projectFilterWidth], the chips take up to half the width, and what is
  /// left has to stay wide enough to type a query into.
  static const double _singleLineWidth = 860;
  static const double _projectFilterWidth = 210;

  final TextEditingController searchController;

  /// Owned by the tab so `Ctrl+F` and `/` have somewhere to send focus.
  final FocusNode searchFocusNode;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final List<Project> projects;
  final String? selectedProjectId;
  final ValueChanged<String?> onProjectChanged;
  final RecordingFilter selectedFilter;
  final Map<RecordingFilter, int> counts;
  final ValueChanged<RecordingFilter> onFilterSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool singleLine = constraints.maxWidth >= _singleLineWidth;
        final Widget search = _SearchField(
          controller: searchController,
          focusNode: searchFocusNode,
          value: searchQuery,
          onChanged: onSearchChanged,
        );
        final Widget? projectFilter = projects.isEmpty
            ? null
            : _ProjectFilter(
                projects: projects,
                selectedId: selectedProjectId,
                onChanged: onProjectChanged,
                compact: singleLine,
              );
        final Widget filters = _FilterRow(
          selected: selectedFilter,
          counts: counts,
          onSelected: onFilterSelected,
        );

        if (!singleLine) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              search,
              if (projectFilter != null) ...<Widget>[
                const SizedBox(height: 12),
                projectFilter,
              ],
              const SizedBox(height: 12),
              filters,
            ],
          );
        }

        return Row(
          children: <Widget>[
            if (projectFilter != null) ...<Widget>[
              SizedBox(width: _projectFilterWidth, child: projectFilter),
              const SizedBox(width: 10),
            ],
            // The only flex child: the chips and the selector claim their
            // natural width first, and the search box takes whatever is left.
            Expanded(child: search),
            const SizedBox(width: 10),
            ConstrainedBox(
              // A bounded box rather than a flex one, so the chips shrink to a
              // scroller only once their labels genuinely outgrow half the
              // strip — a longer count (`READY 1204`) must not start stealing
              // room from the query field.
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
              child: filters,
            ),
          ],
        );
      },
    );
  }
}

class _ProjectFilter extends StatelessWidget {
  const _ProjectFilter({
    required this.projects,
    required this.selectedId,
    required this.onChanged,
    this.compact = false,
  });

  final List<Project> projects;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  /// Drops the floating label and adopts the search box's filled outline, so
  /// the two read as one control beside each other on the single-line strip.
  /// The stacked layout keeps the label — there it has a row to itself and
  /// nothing else names the field.
  final bool compact;

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
      isDense: compact,
      // A project name is free text and the selector has a fixed width on the
      // single-line strip, so the label has to be allowed to ellipsize. Without
      // this the dropdown's own row overflows — and it overflows while laying
      // out the *menu* items offstage, so the visible control looks correct and
      // only the debug stripes say otherwise.
      isExpanded: true,
      // Matched to the search box's 18 px prefix icon: the default 24 would
      // make the dropdown the taller of the two and break the line.
      iconSize: compact ? 18 : 24,
      style: compact ? TextStyle(color: Console.text, fontSize: 13) : null,
      decoration: compact
          ? _fieldDecoration.copyWith(
              hintText: 'All projects',
              prefixIcon: Icon(
                Icons.account_tree_outlined,
                color: Console.dim,
                size: 18,
              ),
            )
          : const InputDecoration(
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

/// Single definition of the review axis, for the same reason [_matches] is one:
/// the chip counts and the list must be answering the same question.
bool _matchesReview(ReviewFilter filter, Recording item) => switch (filter) {
  ReviewFilter.all => true,
  ReviewFilter.desk => !item.isProcessedByUser,
  ReviewFilter.handedOff => item.isProcessedByUser,
};

/// Keyboard control for the queue.
///
/// The app is desktop-first — it ships system-wide global hotkeys — and until
/// this existed the window itself had exactly one key binding in it (Escape,
/// in the editor). Reaching the third card meant roughly fifteen presses of
/// Tab, because every card contributes three to five focusable buttons.
///
/// `CallbackShortcuts` reacts only while focus is inside its subtree, which is
/// why the [focusNode] is `autofocus` and `canRequestFocus`: without a focus
/// owner the bindings would exist and never fire — the same trap the editor's
/// Escape fell into. `skipTraversal` keeps it out of the Tab order, so this
/// node never becomes a stop the user has to press through.
///
/// The single-letter bindings deliberately carry no modifier: they are scoped
/// to this subtree, and the moment focus enters a text field the field consumes
/// the key first, so `e` types an "e" in the search box and edits a row
/// everywhere else.
class _QueueShortcuts extends StatelessWidget {
  const _QueueShortcuts({
    required this.focusNode,
    required this.onNext,
    required this.onPrevious,
    required this.onEdit,
    required this.onToggleProcessed,
    required this.onTogglePlay,
    required this.onRoute,
    required this.onHandoff,
    required this.onSearch,
    required this.onClearFocus,
    required this.child,
  });

  final FocusNode focusNode;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onEdit;
  final VoidCallback onToggleProcessed;
  final VoidCallback onTogglePlay;
  final VoidCallback onRoute;
  final VoidCallback onHandoff;
  final VoidCallback onSearch;
  final VoidCallback onClearFocus;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): onNext,
        const SingleActivator(LogicalKeyboardKey.arrowUp): onPrevious,
        // vi-style, for the same hands that never leave the home row.
        const SingleActivator(LogicalKeyboardKey.keyJ): onNext,
        const SingleActivator(LogicalKeyboardKey.keyK): onPrevious,
        const SingleActivator(LogicalKeyboardKey.keyE): onEdit,
        const SingleActivator(LogicalKeyboardKey.keyD): onToggleProcessed,
        const SingleActivator(LogicalKeyboardKey.keyR): onRoute,
        // `A` for agent. `H` would have read as "handoff" for both of these,
        // and the two destinations must not share a mnemonic.
        const SingleActivator(LogicalKeyboardKey.keyA): onHandoff,
        const SingleActivator(LogicalKeyboardKey.space): onTogglePlay,
        const SingleActivator(LogicalKeyboardKey.escape): onClearFocus,
        // Both spellings: control on Linux/Windows, meta on macOS.
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): onSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): onSearch,
        const SingleActivator(LogicalKeyboardKey.slash): onSearch,
      },
      child: Focus(
        focusNode: focusNode,
        autofocus: true,
        skipTraversal: true,
        child: child,
      ),
    );
  }
}

/// Getters, not top-level variables. A `final`-in-effect module variable is
/// initialised lazily **once**, so the first field ever built would pin that
/// theme's colours into every field for the rest of the process — the same
/// staleness a `const` widget causes, one level up and with no compiler error
/// to announce it. `test/theme_test.dart` scans for both.
OutlineInputBorder get _fieldBorder => OutlineInputBorder(
  borderRadius: const BorderRadius.all(Radius.circular(10)),
  borderSide: BorderSide(color: Console.border),
);

/// The strip's shared field shape. Search and the compact project selector are
/// different widgets on one line, so the decoration has to come from a single
/// place — two hand-copied `OutlineInputBorder`s is exactly how the tabs drifted
/// before `ConsoleField` existed.
InputDecoration get _fieldDecoration => InputDecoration(
  isDense: true,
  contentPadding: const EdgeInsets.symmetric(vertical: 13),
  hintStyle: TextStyle(color: Console.dimText, fontSize: 13),
  prefixIconConstraints: const BoxConstraints(minWidth: 42),
  filled: true,
  // `surfaceRaised` (`--muted`), not `surface`: the field is a *well* inside a
  // panel, and with `surface` it would be a white box on a white card in the
  // light theme.
  fillColor: Console.surfaceRaised,
  border: _fieldBorder,
  enabledBorder: _fieldBorder,
  disabledBorder: _fieldBorder,
  focusedBorder: OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: Console.accent),
  ),
);

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.value,
    required this.onChanged,
    this.focusNode,
  });

  final TextEditingController controller;
  final String value;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      style: TextStyle(color: Console.text, fontSize: 13),
      decoration: _fieldDecoration.copyWith(
        hintText: 'Search captures',
        prefixIcon: Icon(Icons.search, color: Console.dimText, size: 18),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                // Constrained so the clear button cannot make the search box
                // taller than the controls beside it on the single-line strip:
                // an IconButton's default 48 px minimum would do exactly that,
                // and the row would jump the moment the user types.
                constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close, color: Console.dimText, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
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

/// [hasAny] separates "this install has captured nothing" from "the filters
/// excluded everything", which is the same fact the panel's icon and blurb
/// switch on. The review axis wins the wording when it is the one narrowing the
/// list, because clearing the desk is an outcome worth naming rather than an
/// absence to apologise for.
String _emptyLabel(
  RecordingFilter filter,
  ReviewFilter review, {
  required bool hasAny,
}) {
  if (!hasAny) return 'Nothing captured yet.';
  if (filter != RecordingFilter.all && review != ReviewFilter.all) {
    return 'Nothing matches the selected status and review filters.';
  }
  if (filter == RecordingFilter.all) {
    return switch (review) {
      ReviewFilter.desk => "Desk clear — it's all with someone.",
      ReviewFilter.handedOff => 'Nothing handed off yet.',
      ReviewFilter.all => 'Nothing matches the current filters.',
    };
  }
  return switch (filter) {
    RecordingFilter.all => 'Nothing matches the current filters.',
    RecordingFilter.queue => 'The processing queue is empty.',
    RecordingFilter.ready => 'No finished output yet.',
    RecordingFilter.failed => 'No failed jobs.',
    RecordingFilter.raw => 'Nothing waiting to be queued.',
  };
}

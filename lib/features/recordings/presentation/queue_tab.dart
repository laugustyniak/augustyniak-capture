import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_controller.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import 'recording_card.dart';
import 'recording_editor.dart';
import 'recording_row.dart';
import 'recordings_controller.dart';

/// The five buckets from the design. They **partition** the queue: every item
/// matches exactly one of `queue`/`ready`/`failed`/`raw`, and `all` is their
/// union — which is what lets each chip carry a count that adds up.
enum RecordingFilter { all, queue, ready, failed, raw }

/// The design's second axis, and it is deliberately a *different control* from
/// the chips above.
///
/// `Recording` has always carried two independent states: where the pipeline
/// has got to (`RecordingStatus`) and whether the user has dealt with the item
/// (`isProcessedByUser`). The chips filter the first; this filters the second.
/// Before the redesign the review flag was only ever a toggle on a card and a
/// progress bar — visible, but not something you could *stand in*, so the queue
/// had no inbox-zero reading at all.
///
/// [inbox] is the default because that is the question the app is opened to
/// answer: what have I not dealt with yet. Marking an item done therefore takes
/// it out of the list, which is the point rather than a side effect.
enum ReviewFilter { inbox, done, any }

/// The queue screen: header, filters and the capture list. Owns only view
/// state; every mutation goes through [RecordingsController].
class QueueTab extends StatefulWidget {
  const QueueTab({
    super.key,
    required this.controller,
    this.projects,
    this.wide = false,
    this.onOpenCaptureMenu,
  });

  final RecordingsController controller;
  final ProjectsController? projects;

  /// Opens the `+` sheet (note, audio/image/video upload).
  ///
  /// Only the phone layout renders a button for it — the wide layout's rail has
  /// its own. Nullable so a test can pump the tab without a shell; the button
  /// is simply absent then, rather than present and inert.
  final VoidCallback? onOpenCaptureMenu;

  /// Draw the design's desktop form: a one-piece header bar over a multi-column
  /// card grid. False gives the single-column phone form, where the header,
  /// the review progress and the filters stack into the scroll area.
  ///
  /// Passed in rather than measured here so the shell decides once, and the two
  /// layouts cannot disagree about where the breakpoint is.
  final bool wide;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.all;
  ReviewFilter reviewFilter = ReviewFilter.inbox;
  String searchQuery = '';
  String? projectFilterId;
  final TextEditingController searchController = TextEditingController();

  /// Phone only: the header's two collapsible sections. The wide layout has
  /// room to show both permanently, so it never reads either flag.
  bool searchOpen = false;
  bool filtersOpen = false;

  /// Phone only: the row currently opened to reveal its text, tags and tools.
  ///
  /// Separate from [editingId] because reading and editing are different
  /// intents — tapping a row to see what is in it must not put a cursor in it.
  /// One id, like [editingId]: an accordion keeps the list scannable, where a
  /// screen of independently-expanded rows is just the old card list again.
  String? expandedId;

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

    // Counted before the search *and* before the other axis is applied: each
    // control describes the queue it filters, not what the other controls have
    // already narrowed it to. A count that moved when you typed would stop
    // being a fact about the queue.
    final Map<RecordingFilter, int> statusCounts = <RecordingFilter, int>{
      for (final RecordingFilter filter in RecordingFilter.values)
        filter: all.where((Recording item) => _matches(filter, item)).length,
    };
    final Map<ReviewFilter, int> reviewCounts = <ReviewFilter, int>{
      for (final ReviewFilter filter in ReviewFilter.values)
        filter: all
            .where((Recording item) => _matchesReview(filter, item))
            .length,
    };

    return SafeArea(
      bottom: false,
      child: widget.wide
          ? _buildWide(
              all: all,
              visible: visible,
              projects: projects,
              effectiveProjectFilterId: effectiveProjectFilterId,
              statusCounts: statusCounts,
              reviewCounts: reviewCounts,
            )
          : _buildMobile(
              all: all,
              visible: visible,
              projects: projects,
              effectiveProjectFilterId: effectiveProjectFilterId,
              statusCounts: statusCounts,
              reviewCounts: reviewCounts,
            ),
    );
  }

  /// Desktop: a fixed header bar over a scrolling card grid. The header does
  /// not scroll away, because at this width the filters are the primary way
  /// through a queue too long to read.
  Widget _buildWide({
    required List<Recording> all,
    required List<Recording> visible,
    required List<Project> projects,
    required String? effectiveProjectFilterId,
    required Map<RecordingFilter, int> statusCounts,
    required Map<ReviewFilter, int> reviewCounts,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _QueueHeaderBar(
          visibleCount: visible.length,
          searchController: searchController,
          searchQuery: searchQuery,
          onSearchChanged: (String value) =>
              setState(() => searchQuery = value),
          reviewFilter: reviewFilter,
          reviewCounts: reviewCounts,
          onReviewSelected: (ReviewFilter value) =>
              setState(() => reviewFilter = value),
          statusFilter: selectedFilter,
          statusCounts: statusCounts,
          onStatusSelected: (RecordingFilter value) =>
              setState(() => selectedFilter = value),
          projects: projects,
          selectedProjectId: effectiveProjectFilterId,
          onProjectChanged: (String? value) =>
              setState(() => projectFilterId = value),
        ),
        if (widget.controller.error != null) ...<Widget>[
          const SizedBox(height: 8),
          ErrorBanner(message: widget.controller.error!),
        ],
        Expanded(
          child: visible.isEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: EmptyPanel(
                    icon: Icons.graphic_eq,
                    title: _emptyLabel(
                      selectedFilter,
                      reviewFilter,
                      all.length,
                    ),
                    blurb: _emptyBlurb,
                  ),
                )
              : _CardGrid(items: visible, buildItem: _buildRow),
        ),
      ],
    );
  }

  /// Phone: a one-line header over a dense list of rows that open in place.
  ///
  /// Everything that is not the list is collapsed behind a toggle, because on
  /// a 393 px screen the previous form spent roughly half the height on chrome
  /// — an eyebrow, a 26 px title, a progress strip, a search field, a project
  /// dropdown and a chip row — before the first capture. The counts that strip
  /// used to carry now ride on the review switch itself (`INBOX 4 · DONE 33`),
  /// which is why losing it costs no information.
  Widget _buildMobile({
    required List<Recording> all,
    required List<Recording> visible,
    required List<Project> projects,
    required String? effectiveProjectFilterId,
    required Map<RecordingFilter, int> statusCounts,
    required Map<ReviewFilter, int> reviewCounts,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MobileHeader(
          segments: _reviewSegments(reviewCounts),
          reviewFilter: reviewFilter,
          onReviewSelected: (ReviewFilter value) =>
              setState(() => reviewFilter = value),
          searchOpen: searchOpen,
          onToggleSearch: _toggleSearch,
          filtersOpen: filtersOpen,
          onToggleFilters: () => setState(() => filtersOpen = !filtersOpen),
          onOpenCaptureMenu: widget.onOpenCaptureMenu,
          searchController: searchController,
          searchQuery: searchQuery,
          onSearchChanged: (String value) =>
              setState(() => searchQuery = value),
          statusFilter: selectedFilter,
          statusCounts: statusCounts,
          onStatusSelected: (RecordingFilter value) =>
              setState(() => selectedFilter = value),
          projects: projects,
          selectedProjectId: effectiveProjectFilterId,
          onProjectChanged: (String? value) =>
              setState(() => projectFilterId = value),
        ),
        if (widget.controller.error != null) ...<Widget>[
          const SizedBox(height: 8),
          ErrorBanner(message: widget.controller.error!),
        ],
        Expanded(
          child: visible.isEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 18, 14, 24),
                  child: EmptyPanel(
                    icon: Icons.graphic_eq,
                    title: _emptyLabel(
                      selectedFilter,
                      reviewFilter,
                      all.length,
                    ),
                    blurb: _emptyBlurb,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 20),
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _buildMobileRow(visible[index]),
                ),
        ),
      ],
    );
  }

  /// Opening the search box focuses it; closing it clears the query.
  ///
  /// Clearing on close is the point of the toggle: a collapsed search field
  /// that is still filtering the list is a queue that looks broken, with
  /// nothing on screen explaining why half of it is missing.
  void _toggleSearch() {
    setState(() {
      searchOpen = !searchOpen;
      if (!searchOpen) {
        searchController.clear();
        searchQuery = '';
      }
    });
  }

  /// One phone row: the dense summary, the editor when this is the row being
  /// edited. Expansion and editing are separate states on purpose — tapping a
  /// row to read it must not put a cursor in it.
  Widget _buildMobileRow(Recording recording) {
    final RecordingsController controller = widget.controller;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: recording.id == editingId
          ? Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _buildEditor(recording),
            )
          : RecordingRow(
              key: ValueKey<String>('row-${recording.id}'),
              recording: recording,
              expanded: recording.id == expandedId,
              isPlaying: controller.playingId == recording.id,
              isEnriching: controller.isEnriching(recording.id),
              projectName: _projectName(recording.projectId),
              onTap: () => setState(() {
                expandedId = recording.id == expandedId ? null : recording.id;
              }),
              onTogglePlay: () => controller.togglePlayback(recording.id),
              onOpen: () => controller.openSource(recording.id),
              onRetry: () => controller.retryTranscription(recording.id),
              onEdit: () => setState(() => editingId = recording.id),
              onToggleProcessed: () async {
                unawaited(HapticFeedback.selectionClick());
                await controller.toggleProcessed(recording.id);
              },
            ),
    );
  }

  /// One queue row, in whichever of its two modes it is currently in.
  ///
  /// The row grows into the editor in place. Animating the height is what keeps
  /// the rows below from jumping — the edited item has to stay under the finger
  /// that opened it.
  Widget _buildRow(Recording recording) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: recording.id == editingId
          ? _buildEditor(recording)
          : _buildCard(recording),
    );
  }

  List<(ReviewFilter, String)> _reviewSegments(Map<ReviewFilter, int> counts) {
    return <(ReviewFilter, String)>[
      for (final ReviewFilter filter in ReviewFilter.values)
        (filter, '${filter.name.toUpperCase()} ${counts[filter] ?? 0}'),
    ];
  }

  List<Recording> _filter(
    List<Recording> recordings,
    String? effectiveProjectFilterId,
  ) {
    final List<Recording> byStatus = recordings
        .where(
          (Recording item) =>
              _matches(selectedFilter, item) &&
              _matchesReview(reviewFilter, item) &&
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

/// The design's `grid-template-columns: repeat(auto-fill, minmax(430px, 1fr))`,
/// as a list of rows.
///
/// A `GridView` is the wrong tool here: every one of its delegates wants a
/// fixed extent or a fixed aspect ratio, and a queue card's height depends on
/// its own content — a transcript, a tag row, an inline editor three times the
/// height of the card it replaced. Rows of `Expanded` cells reproduce CSS
/// grid's `align-items: start` exactly: equal column widths, each cell as tall
/// as it needs to be, the row as tall as its tallest cell.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.items, required this.buildItem});

  final List<Recording> items;
  final Widget Function(Recording) buildItem;

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // `auto-fill` with a 430 px minimum: fit as many whole columns as the
        // width allows, never fewer than one — below the minimum a single
        // stretched column is still the right answer, which is what `1fr` does.
        final double available = constraints.maxWidth - 40;
        final int columns = math.max(
          1,
          ((available + _gap) / (Console.gridColumnMin + _gap)).floor(),
        );
        final int rows = (items.length / columns).ceil();

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          itemCount: rows,
          itemBuilder: (BuildContext context, int row) {
            final int start = row * columns;
            return Padding(
              padding: const EdgeInsets.only(bottom: _gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int column = 0; column < columns; column++) ...<Widget>[
                    if (column > 0) const SizedBox(width: _gap),
                    Expanded(
                      child: start + column < items.length
                          // Keyed by id: without it, a row losing an item would
                          // hand the editor's element to whichever capture slid
                          // into that grid slot.
                          ? KeyedSubtree(
                              key: ValueKey<String>(items[start + column].id),
                              child: buildItem(items[start + column]),
                            )
                          // Holds the column open so a short last row's cards
                          // keep the same width as every other row's.
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// The wide layout's fixed header: title and review switch on one line, the
/// query controls on the next.
///
/// Two lines rather than the design's single wrapping row. The design was drawn
/// at 1512 px, where all six controls fit; a wrapping row at 1000 px reflows
/// unpredictably as counts gain digits, and a header whose height changes while
/// you type is worse than one that is reliably two lines tall.
class _QueueHeaderBar extends StatelessWidget {
  const _QueueHeaderBar({
    required this.visibleCount,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.reviewFilter,
    required this.reviewCounts,
    required this.onReviewSelected,
    required this.statusFilter,
    required this.statusCounts,
    required this.onStatusSelected,
    required this.projects,
    required this.selectedProjectId,
    required this.onProjectChanged,
  });

  final int visibleCount;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final ReviewFilter reviewFilter;
  final Map<ReviewFilter, int> reviewCounts;
  final ValueChanged<ReviewFilter> onReviewSelected;
  final RecordingFilter statusFilter;
  final Map<RecordingFilter, int> statusCounts;
  final ValueChanged<RecordingFilter> onStatusSelected;
  final List<Project> projects;
  final String? selectedProjectId;
  final ValueChanged<String?> onProjectChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(bottom: BorderSide(color: Console.track)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('Queue', style: ConsoleText.barTitle),
              const SizedBox(width: 14),
              ConsoleSegmented<ReviewFilter>(
                segments: <(ReviewFilter, String)>[
                  for (final ReviewFilter filter in ReviewFilter.values)
                    (
                      filter,
                      '${filter.name.toUpperCase()} '
                          '${reviewCounts[filter] ?? 0}',
                    ),
                ],
                selected: reviewFilter,
                onSelected: onReviewSelected,
              ),
              const Spacer(),
              Text('$visibleCount shown', style: ConsoleText.counter),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SizedBox(
                width: 300,
                child: _SearchField(
                  controller: searchController,
                  value: searchQuery,
                  onChanged: onSearchChanged,
                ),
              ),
              if (projects.isNotEmpty) ...<Widget>[
                const SizedBox(width: 12),
                SizedBox(
                  width: 190,
                  child: _ProjectFilter(
                    projects: projects,
                    selectedId: selectedProjectId,
                    onChanged: onProjectChanged,
                    compact: true,
                  ),
                ),
              ],
              const SizedBox(width: 12),
              Expanded(
                child: _FilterRow(
                  selected: statusFilter,
                  counts: statusCounts,
                  onSelected: onStatusSelected,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The phone layout's header: one line always, two more on request.
///
/// The review switch is the only control that is never collapsed, because it
/// is the one that decides what the list *is*. Search and the status/project
/// filters both hide behind a toggle — they are used occasionally, and each one
/// permanently on screen costs a capture's worth of list.
class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.segments,
    required this.reviewFilter,
    required this.onReviewSelected,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.filtersOpen,
    required this.onToggleFilters,
    required this.onOpenCaptureMenu,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.statusFilter,
    required this.statusCounts,
    required this.onStatusSelected,
    required this.projects,
    required this.selectedProjectId,
    required this.onProjectChanged,
  });

  final List<(ReviewFilter, String)> segments;
  final ReviewFilter reviewFilter;
  final ValueChanged<ReviewFilter> onReviewSelected;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final bool filtersOpen;
  final VoidCallback onToggleFilters;
  final VoidCallback? onOpenCaptureMenu;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final RecordingFilter statusFilter;
  final Map<RecordingFilter, int> statusCounts;
  final ValueChanged<RecordingFilter> onStatusSelected;
  final List<Project> projects;
  final String? selectedProjectId;
  final ValueChanged<String?> onProjectChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(bottom: BorderSide(color: Console.track)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Scrollable rather than shrunk: three segments carrying
              // three-digit counts outgrow a 393 px screen, and a switch whose
              // labels ellipsise stops being readable as a set of options.
              //
              // `Expanded`, and **no** `Spacer` beside it: a spacer is itself
              // flexible, so the two split the free width and the switch got
              // clipped mid-word while empty space sat to its right. Taking all
              // the remaining width and aligning the content left pins the
              // buttons to the right edge and still lets the switch scroll.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConsoleSegmented<ReviewFilter>(
                    segments: segments,
                    selected: reviewFilter,
                    onSelected: onReviewSelected,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (onOpenCaptureMenu != null) ...<Widget>[
                ConsoleIconButton(
                  icon: Icons.add_rounded,
                  onTap: onOpenCaptureMenu!,
                  semanticLabel: 'New note or upload',
                  size: 34,
                  iconSize: 17,
                ),
                const SizedBox(width: 6),
              ],
              ConsoleIconButton(
                icon: Icons.search_rounded,
                onTap: onToggleSearch,
                semanticLabel: 'Search',
                active: searchOpen,
                size: 34,
                iconSize: 16,
              ),
              const SizedBox(width: 6),
              ConsoleIconButton(
                icon: Icons.tune_rounded,
                onTap: onToggleFilters,
                semanticLabel: 'Filters',
                // Stays lit while a filter is actually narrowing the list, not
                // only while the panel is open: a closed panel hiding an active
                // filter is the one way this header can lie about what is on
                // screen.
                active:
                    filtersOpen ||
                    statusFilter != RecordingFilter.all ||
                    selectedProjectId != null,
                size: 34,
                iconSize: 16,
              ),
            ],
          ),
          if (searchOpen) ...<Widget>[
            const SizedBox(height: 8),
            _SearchField(
              controller: searchController,
              value: searchQuery,
              onChanged: onSearchChanged,
              autofocus: true,
            ),
          ],
          if (filtersOpen) ...<Widget>[
            const SizedBox(height: 8),
            _FilterRow(
              selected: statusFilter,
              counts: statusCounts,
              onSelected: onStatusSelected,
            ),
            if (projects.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _ProjectFilter(
                projects: projects,
                selectedId: selectedProjectId,
                onChanged: onProjectChanged,
                compact: true,
              ),
            ],
          ],
        ],
      ),
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

  /// Drop the floating `Project` label and match the search field's height.
  ///
  /// Not cosmetic: a `labelText` reserves the space the label floats into, and
  /// a `prefixIcon` imposes Material's own 48 px minimum, so the default form
  /// of this control is ~16 px taller than the field beside it — enough to
  /// overflow the wide layout's header row. Both are worth paying for in the
  /// phone layout, where the control sits alone in a column and the label is
  /// the only thing naming it.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(9)),
      borderSide: BorderSide(color: Console.border),
    );

    return DropdownButtonFormField<String?>(
      // FormField owns its selected value internally. Recreate that state when
      // the controlled selection or project vocabulary changes; otherwise a
      // deleted project can remain as a dangling Dropdown value for one frame.
      key: ValueKey<String>(
        'project-filter:${selectedId ?? 'all'}:'
        '${projects.map((Project project) => project.id).join(',')}',
      ),
      initialValue: selectedId,
      isDense: true,
      // A `DropdownButton` sizes itself to its *widest* item, so inside the
      // header bar's fixed 190 px slot a long project name overflows sideways
      // without this. It is not what caused the header's vertical overflow —
      // that was the `labelText` and the prefix icon's 48 px floor, both of
      // which `compact` drops below.
      isExpanded: true,
      style: const TextStyle(
        fontFamily: ConsoleFont.display,
        fontSize: 12.5,
        color: Console.textSoft,
      ),
      icon: const Icon(
        Icons.keyboard_arrow_down_rounded,
        size: 16,
        color: Console.dim,
      ),
      dropdownColor: Console.surfaceRaised,
      decoration: compact
          ? const InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Console.surface,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
              prefixIcon: Icon(
                Icons.account_tree_outlined,
                size: 16,
                color: Console.dim,
              ),
              prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 0),
              border: border,
              enabledBorder: border,
              focusedBorder: border,
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
            child: Text(project.name, overflow: TextOverflow.ellipsis),
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

/// The review axis' counterpart to [_matches]. Same rule: one definition drives
/// both the segment counts and the list.
bool _matchesReview(ReviewFilter filter, Recording item) => switch (filter) {
  ReviewFilter.inbox => !item.isProcessedByUser,
  ReviewFilter.done => item.isProcessedByUser,
  ReviewFilter.any => true,
};

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.value,
    required this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String value;
  final ValueChanged<String> onChanged;

  /// Set by the phone header, where this field only exists because the user
  /// just tapped the magnifier — asking for a second tap to reach the cursor
  /// would make the toggle worse than the always-visible field it replaced.
  ///
  /// The cost is the one the project already documents for focused fields: a
  /// blinking cursor never stops scheduling frames, so a test that opens the
  /// search must pump explicit durations rather than `pumpAndSettle`.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    const OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(9)),
      borderSide: BorderSide(color: Console.border),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: autofocus,
      style: const TextStyle(color: Console.text, fontSize: 12.5),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        hintText: 'Search captures',
        hintStyle: const TextStyle(color: Console.dim, fontSize: 12.5),
        prefixIcon: const Icon(Icons.search, color: Console.dim, size: 17),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: Console.dim, size: 17),
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
          borderRadius: BorderRadius.all(Radius.circular(9)),
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

const String _emptyBlurb =
    'Every capture is written to disk and verified '
    'before processing is even attempted.';

/// Names whichever filter is actually responsible for the empty list.
///
/// [total] is checked first, and it is the whole reason this takes three
/// arguments: with nothing captured at all, *every* filter is empty, and
/// "inbox zero" would congratulate a fresh install on work it has not done.
/// After that the review axis wins over the status axis, because it is the one
/// that hides items the user just dealt with — "you are caught up" and "there
/// is no finished output" are different facts, and reporting the second while
/// the queue is merely cleared reads as a bug.
String _emptyLabel(RecordingFilter filter, ReviewFilter review, int total) {
  if (total == 0) return 'Nothing captured yet.';
  if (filter == RecordingFilter.all) {
    return switch (review) {
      ReviewFilter.inbox => 'Inbox zero. Nothing left to review.',
      ReviewFilter.done => 'Nothing marked done yet.',
      ReviewFilter.any => 'Nothing captured yet.',
    };
  }
  return switch (filter) {
    RecordingFilter.all => 'Nothing captured yet.',
    RecordingFilter.queue => 'The processing queue is empty.',
    RecordingFilter.ready => 'No finished output yet.',
    RecordingFilter.failed => 'No failed jobs.',
    RecordingFilter.raw => 'Nothing waiting to be queued.',
  };
}

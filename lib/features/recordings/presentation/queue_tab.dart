import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/ui_kit.dart';
import '../../costs/data/usage_repository.dart';
import '../../costs/domain/price_book.dart';
import '../../costs/domain/usage_event.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_controller.dart';
import '../domain/agent_artifact.dart';
import '../domain/capture_category.dart';
import '../domain/recording.dart';
import '../domain/route_record.dart';
import 'agent_artifact_viewer_modal.dart';
import 'capture_focus_view.dart';
import 'card_parts.dart';
import 'compact_queue_header.dart';
import 'handoff_sheet.dart';
import 'queue_toolbar.dart';
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
    this.hasTranscriptionProfile = true,
    this.onConfigureModels,
    this.usageRepository,
    this.storagePrice = StoragePrice.defaults,
  });

  final RecordingsController controller;
  final ProjectsController? projects;
  final String? initialProjectId;

  /// Whether audio captured here has anywhere to be transcribed.
  ///
  /// **Defaults to true, and that default is the safe one.** The claim this
  /// flag makes is "your setup is unfinished", which is worth making only when
  /// the shell has actually looked at the settings; a caller that does not pass
  /// it (every existing widget test) must not have the first-run prompt
  /// invented for it. The shell answers `settings.activeProfile != null`.
  ///
  /// Deliberately narrower than "nothing is configured": a text note needs no
  /// profile at all, so this gates a message about *audio*, not about the app.
  final bool hasTranscriptionProfile;

  /// Takes the user to the Models tab. Null where there is no tab to go to, in
  /// which case the prompt still states the problem and simply offers no
  /// button — a control that does nothing is worse than no control.
  final VoidCallback? onConfigureModels;

  /// Null until the shell's database open resolves (or on a build that never
  /// opened one) — the editor's `COST` section reads through this the same way
  /// the Config tab's PRICING section does, and renders nothing while it is
  /// null rather than a section with no data behind it.
  final UsageRepository? usageRepository;

  /// What the capture's stored source costs to keep, per GB-month. Read off
  /// `AppSettings.storagePrice` by the shell, which already three-state-
  /// defaults to [StoragePrice.defaults] for an install that never overrode
  /// a rate.
  final StoragePrice storagePrice;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  RecordingFilter selectedFilter = RecordingFilter.all;
  ReviewFilter reviewFilter = ReviewFilter.desk;
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

  /// Desktop completion feedback has to outlive the card: the default Desk
  /// filter removes a capture the moment its durable review write lands. The
  /// in-card spinner covers the write; this small overlay carries the result
  /// across that removal so the disappearing row reads as an outcome, not a
  /// glitch.
  final Set<String> markingDoneIds = <String>{};
  _DoneFeedbackState? doneFeedback;
  int _doneFeedbackSequence = 0;
  Timer? _doneFeedbackTimer;

  /// Whether the compact header's two panels are open *by the user's hand*.
  ///
  /// Not the whole answer: a panel whose control is engaged is forced open
  /// regardless, so a query or a status filter can never be the invisible reason
  /// the list is short. See [CompactQueueHeader]. Both are ignored in the wide
  /// forms, where the controls are always on screen.
  bool searchPanelOpen = false;
  bool filterPanelOpen = false;

  final FocusNode searchFocus = FocusNode();
  final FocusNode listFocus = FocusNode(debugLabel: 'queue-shortcuts');

  bool _isSyncing = false;

  /// Every visible capture's summed cost, refreshed once per [build] from
  /// `widget.usageRepository` — a single grouped query rather than one lookup
  /// per row. `_buildCard`/`_buildMobileRow` read it by id; a capture absent
  /// from it (no repository yet, or every one of its events unpriced) passes
  /// null through to `VerificationLine`, which renders `cost —`.
  Map<String, double> _costTotals = const <String, double>{};

  Future<void> _handleSync(
    BuildContext context,
    RecordingsController controller,
  ) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      // Pull-to-refresh is one of the two moments Command outcomes are read
      // back — the other is the app coming to the foreground. Never a timer:
      // nothing here is worth a wake-up, and a phone polling a homelab on a
      // schedule spends battery with nobody waiting on the answer.
      unawaited(controller.refreshCommandOutcomes());
      final bool ok = await controller.syncTurso();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? '⚡ Turso & R2 sync complete!'
                  : '⚠️ Turso sync skipped or failed.',
            ),
            backgroundColor: ok ? Console.green : Console.amber,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

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
    _doneFeedbackTimer?.cancel();
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
    // Resolved once here, not once per card: `totalsByCapture()` is a single
    // grouped query, and a thousand-row queue must not turn into a thousand
    // repository reads on every pipeline tick.
    _costTotals =
        widget.usageRepository?.totalsByCapture() ?? const <String, double>{};
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
          onToggleProcessed: () => _onFocused(visible, _toggleProcessed),
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
          onOpen: () => _onFocused(visible, _openFocus),
          onClearFocus: () => setState(() => focusedId = null),
          child: Stack(
            children: <Widget>[
              SafeArea(
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
                          action: ElevatedButton.icon(
                            icon: SyncSpinIcon(
                              isSyncing: _isSyncing,
                              size: 14,
                              color: Colors.black,
                            ),
                            label: Text(_isSyncing ? 'SYNCING…' : 'SYNC TURSO'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Console.green,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: Console.green.withValues(
                                alpha: 0.8,
                              ),
                              disabledForegroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            onPressed: _isSyncing
                                ? null
                                : () => _handleSync(context, controller),
                          ),
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
                        onSync: () => _handleSync(context, controller),
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
                        search: QueueSearchField(
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
                              QueueProjectFilter(
                                projects: projects,
                                selectedId: effectiveProjectFilterId,
                                onChanged: (String? value) {
                                  setState(() => projectFilterId = value);
                                },
                              ),
                              const SizedBox(height: 10),
                            ],
                            QueueStatusChips(
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
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: QueueToolbar(
                          total: all.length,
                          reviewed: reviewedCount,
                          reviewFilter: reviewFilter,
                          onReviewChanged: (ReviewFilter value) {
                            setState(() => reviewFilter = value);
                          },
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
                          statusFilter: selectedFilter,
                          counts: counts,
                          onStatusChanged: (RecordingFilter value) {
                            setState(() => selectedFilter = value);
                          },
                        ),
                      ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () => _handleSync(context, controller),
                        color: Console.accent,
                        backgroundColor: Console.surface,
                        // **`.builder`, not `children:`.** A keyed child list
                        // builds every element the moment the list does, and
                        // this list is rebuilt on every `notifyListeners()` —
                        // which the pipeline emits per status transition, per
                        // poster, per enrichment. With `children:` a queue of
                        // four hundred captures paid for four hundred
                        // `RecordingCard` subtrees to move one status pill. The
                        // builder pays for the viewport.
                        child: visible.isEmpty
                            ? ListView(
                                padding: _listPadding(compact),
                                children: <Widget>[
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: _emptyPanel(all),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                padding: _listPadding(compact),
                                itemCount: visible.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final Recording recording = visible[index];
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      4,
                                      0,
                                      4,
                                      10,
                                    ),
                                    // The row grows into the editor in place.
                                    // Animating the height is what keeps the
                                    // rows below from jumping — the edited item
                                    // has to stay under the finger that opened
                                    // it.
                                    child: AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      alignment: Alignment.topCenter,
                                      child: recording.id == editingId
                                          ? _buildEditor(recording)
                                          : compact
                                          ? _buildMobileRow(recording)
                                          : _buildCard(recording),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 20,
                bottom: 22,
                child: IgnorePointer(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    reverseDuration: const Duration(milliseconds: 140),
                    transitionBuilder:
                        (Widget child, Animation<double> animation) {
                          final Animation<Offset> offset =
                              Tween<Offset>(
                                begin: const Offset(0, .18),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              );
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: offset,
                              child: child,
                            ),
                          );
                        },
                    child: doneFeedback == null
                        ? const SizedBox.shrink()
                        : _DoneFeedback(
                            key: ValueKey<String>(
                              '${doneFeedback!.id}:${doneFeedback!.phase.name}',
                            ),
                            state: doneFeedback!,
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Shared by both branches of the list so the empty panel and the rows sit in
  /// the same gutter. Two literals drifted apart is exactly how an empty state
  /// ends up inset differently from the list it replaces.
  EdgeInsets _listPadding(bool compact) => compact
      ? const EdgeInsets.fromLTRB(10, 6, 10, 24)
      : const EdgeInsets.fromLTRB(16, 14, 16, 190);

  /// Why the list is empty, in the user's terms.
  ///
  /// **Three causes, not two.** A filter can be hiding the work, or nothing has
  /// been captured — and those were already told apart. The third is the one
  /// this app got wrong for its whole life: a fresh install has no provider
  /// profile, so every audio capture lands `failed`, and the panel greeting
  /// that user advertised the durability guarantee ("written to disk and
  /// verified before processing is even attempted") to someone staring at a red
  /// row. It is a true sentence and the least useful one available. The setup
  /// case is checked first because it outranks the other two: a filter is
  /// something the user did, an unconfigured endpoint is something the app
  /// never asked them to do.
  Widget _emptyPanel(List<Recording> all) {
    if (all.isEmpty && !widget.hasTranscriptionProfile) {
      return EmptyPanel(
        icon: Icons.memory_outlined,
        tone: Console.amber,
        title: 'No transcription model configured.',
        blurb:
            'Recordings are saved and kept either way — but nothing will be '
            'transcribed until a provider profile is active. Text notes work '
            'without one.',
        action: widget.onConfigureModels == null
            ? null
            : TextButton.icon(
                onPressed: widget.onConfigureModels,
                icon: const Icon(Icons.tune, size: 17),
                label: const Text('SET UP A MODEL'),
              ),
      );
    }
    return EmptyPanel(
      // An empty list has two very different causes and they look identical:
      // nothing was captured, or a filter is hiding what was. Naming the filter
      // that emptied the list is the whole difference between "you are done"
      // and "you cannot see your work".
      icon: all.isEmpty ? Icons.graphic_eq : Icons.inbox_outlined,
      title: _emptyLabel(selectedFilter, reviewFilter, hasAny: all.isNotEmpty),
      blurb: all.isEmpty
          ? 'Every capture is written to disk and verified before processing '
                'is even attempted.'
          : 'Adjust the review, status, project, or search filters to broaden '
                'the queue.',
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
      // Keep an optimistically updated row visible until its disk write
      // settles, otherwise the default Desk filter removes the very spinner
      // that tells the user the Done action is still in progress.
      if (markingDoneIds.contains(item.id)) return true;
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
      isMarkingDone: markingDoneIds.contains(recording.id),
      canRoute: controller.canRoute(recording),
      onRoute: () => controller.route(recording.id),
      canHandoff: controller.canHandoff(recording),
      onHandoff: () => _openHandoff(recording),
      onOpenOutcome: controller.openCommandOutcome,
      canOpenOutcome: (RouteOutcome outcome) =>
          controller.commandOutcomeUrl(outcome) != null,
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
      onToggleProcessed: () => _toggleProcessed(recording),
      onOpenFocus: () => _openFocus(recording),
      costUsd: _costTotals[recording.id],
    );
  }

  /// Opens the capture's reading view. The one destination for "show me this
  /// note": the card body, the card's focus button, the compact row and the
  /// keyboard's Enter all land here, so there is a single answer to what
  /// opening a capture does.
  void _openFocus(Recording recording) {
    setState(() => focusedId = recording.id);
    showCaptureFocusView(
      context,
      controller: widget.controller,
      recordingId: recording.id,
      projectName: _projectName(recording.projectId),
      onEdit: () => setState(() => editingId = recording.id),
      costUsd: _costTotals[recording.id],
    );
  }

  Future<void> _toggleProcessed(Recording recording) async {
    final RecordingsController controller = widget.controller;
    // Reopening an off-desk item is an immediate reversible action. The richer
    // sequence is reserved for Done, where the default filter removes the card
    // and would otherwise erase all visual feedback with it.
    if (recording.isProcessedByUser) {
      await controller.toggleProcessed(recording.id);
      return;
    }
    if (markingDoneIds.contains(recording.id)) return;

    final int sequence = ++_doneFeedbackSequence;
    setState(() {
      markingDoneIds.add(recording.id);
      doneFeedback = _DoneFeedbackState(
        id: recording.id,
        phase: _DoneFeedbackPhase.saving,
      );
    });
    // Cosmetic feedback never gates the disk write.
    unawaited(HapticFeedback.selectionClick());

    try {
      await controller.toggleProcessed(recording.id);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        markingDoneIds.remove(recording.id);
        if (sequence == _doneFeedbackSequence) {
          doneFeedback = _DoneFeedbackState(
            id: recording.id,
            phase: _DoneFeedbackPhase.failed,
          );
        }
      });
      _scheduleFeedbackDismiss(sequence, const Duration(milliseconds: 1800));
      return;
    }

    if (!mounted) return;
    setState(() {
      markingDoneIds.remove(recording.id);
      if (sequence == _doneFeedbackSequence) {
        doneFeedback = _DoneFeedbackState(
          id: recording.id,
          phase: _DoneFeedbackPhase.done,
        );
      }
    });
    _scheduleFeedbackDismiss(sequence, const Duration(milliseconds: 1100));
  }

  void _scheduleFeedbackDismiss(int sequence, Duration delay) {
    if (sequence != _doneFeedbackSequence) return;
    _doneFeedbackTimer?.cancel();
    _doneFeedbackTimer = Timer(delay, () {
      if (!mounted || sequence != _doneFeedbackSequence) return;
      setState(() => doneFeedback = null);
    });
  }

  /// Narrow layouts use a one-line row; tapping it opens the same focus view
  /// the desktop card opens, which is where the capture's content and every
  /// action on it now live.
  Widget _buildMobileRow(Recording recording) {
    final RecordingsController controller = widget.controller;
    return RecordingRow(
      key: ValueKey<String>('row-${recording.id}'),
      recording: recording,
      focused: recording.id == focusedId,
      isEnriching: controller.isEnriching(recording.id),
      onTap: () => _openFocus(recording),
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
      // Resolved here rather than handed to the editor as a repository: the
      // editor's `CostSection` stays a pure widget over a plain list, the same
      // rule `revisions` already follows for `RevisionHistorySection`. Null
      // repository (database not open yet) degrades to no events at all.
      usageEvents:
          widget.usageRepository?.forCapture(recording.id) ??
          const <UsageEvent>[],
      storagePrice: widget.storagePrice,
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

enum _DoneFeedbackPhase { saving, done, failed }

class _DoneFeedbackState {
  const _DoneFeedbackState({required this.id, required this.phase});

  final String id;
  final _DoneFeedbackPhase phase;
}

/// A compact desktop status capsule rather than a snackbar: it belongs to the
/// queue action, never covers content, and does not ask to be dismissed.
class _DoneFeedback extends StatelessWidget {
  const _DoneFeedback({super.key, required this.state});

  final _DoneFeedbackState state;

  @override
  Widget build(BuildContext context) {
    final bool failed = state.phase == _DoneFeedbackPhase.failed;
    final bool saving = state.phase == _DoneFeedbackPhase.saving;
    final Color color = failed ? Console.redSoft : Console.green;
    final String label = failed
        ? 'Could not move · try again'
        : saving
        ? 'Moving to Done…'
        : 'Moved to Done';

    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Console.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .42)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Console.shadow,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (saving)
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: color,
                  backgroundColor: color.withValues(alpha: .16),
                ),
              )
            else
              Icon(
                failed ? Icons.error_outline_rounded : Icons.check_rounded,
                size: 18,
                color: color,
              ),
            const SizedBox(width: 9),
            Text(
              label.toUpperCase(),
              style: ConsoleText.chip.copyWith(color: color),
            ),
          ],
        ),
      ),
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
    required this.onOpen,
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
  final VoidCallback onOpen;
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
        // Reading a capture is what the list is *for*, so it takes the key a
        // list already means it with. `O` would have been a second mnemonic
        // for the one thing every row does.
        const SingleActivator(LogicalKeyboardKey.enter): onOpen,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onOpen,
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

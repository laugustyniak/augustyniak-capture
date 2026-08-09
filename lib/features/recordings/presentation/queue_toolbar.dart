import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../../projects/domain/project.dart';
import 'queue_tab.dart';
import 'review_segments.dart';

/// Getters, not top-level variables. A `final`-in-effect module variable is
/// initialised lazily **once**, so the first field ever built would pin that
/// theme's colours into every field for the rest of the process — the same
/// staleness a `const` widget causes, one level up and with no compiler error
/// to announce it. `test/theme_test.dart` scans for both.
OutlineInputBorder get queueFieldBorder => OutlineInputBorder(
  borderRadius: const BorderRadius.all(Radius.circular(10)),
  borderSide: BorderSide(color: Console.border),
);

/// The toolbar's shared field shape. Search and the project selector are
/// different widgets on one line, so the decoration has to come from a single
/// place — two hand-copied `OutlineInputBorder`s is exactly how the tabs drifted
/// before `ConsoleField` existed.
InputDecoration get queueFieldDecoration => InputDecoration(
  isDense: true,
  contentPadding: const EdgeInsets.symmetric(vertical: 11),
  hintStyle: TextStyle(color: Console.dimText, fontSize: 13),
  prefixIconConstraints: const BoxConstraints(minWidth: 38),
  filled: true,
  // `surfaceRaised` (`--muted`), not `surface`: the field is a *well* inside a
  // panel, and with `surface` it would be a white box on a white card in the
  // light theme.
  fillColor: Console.surfaceRaised,
  border: queueFieldBorder,
  enabledBorder: queueFieldBorder,
  disabledBorder: queueFieldBorder,
  focusedBorder: OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: Console.accent),
  ),
);

/// Everything above the queue list, on one line.
///
/// It replaces a header block that had grown to four stacked rows — the review
/// progress strip, the search box, the project selector and five status chips —
/// costing roughly 300 px before the first capture was drawn. That stacking was
/// not a choice: the old strip had a single-line branch gated at 860 px while
/// the page is capped at [ConsolePageWidth.maxWidth] (880) minus its padding,
/// i.e. 832. **The branch could never run in the app**, only in a widget test
/// that sized its own window, so every real desktop window got the phone-shaped
/// stack.
///
/// Fitting it honestly meant giving up one thing, and it is the status chips:
/// five pills with counts cannot share a line with a segmented control, a
/// project selector and a field wide enough to type into. They become
/// [QueueStatusMenu], which keeps the active bucket and its count on the bar and
/// puts the other four one click away — still counted, so the menu can still
/// answer "how many failed" without changing the list.
///
/// The handed-off ratio survives as the 2 px hairline under the bar, down from a
/// 4 px bar inside a 72 px panel. Its `n / m` caption does **not**, and that was
/// measured rather than guessed: `OFF DESK 100` and `ANY 116` sit 60 px from a
/// `100 / 116` built out of exactly those two numbers, and the caption was
/// taking 74 px from the one control that genuinely needs width. The phone form
/// dropped the same caption for the same reason a release earlier. The ratio is
/// still spoken — the line carries the sentence in its semantics — and still
/// visible, on the segments the user taps to act on it.
class QueueToolbar extends StatelessWidget {
  QueueToolbar({
    super.key,
    required this.total,
    required this.reviewed,
    required this.reviewFilter,
    required this.onReviewChanged,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.projects,
    required this.selectedProjectId,
    required this.onProjectChanged,
    required this.statusFilter,
    required this.counts,
    required this.onStatusChanged,
  });

  /// Below this the bar splits into two rows. Derived from what the row needs
  /// rather than from a device class: the segments, the status button and the
  /// selector claim a fixed share, and what is left has to stay wide enough to
  /// read a query back in.
  static const double singleLineWidth = 700;
  static const double _projectWidth = 156;

  final int total;
  final int reviewed;
  final ReviewFilter reviewFilter;
  final ValueChanged<ReviewFilter> onReviewChanged;

  final TextEditingController searchController;

  /// Owned by the tab so `Ctrl+F` and `/` have somewhere to send focus.
  final FocusNode searchFocusNode;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;

  final List<Project> projects;
  final String? selectedProjectId;
  final ValueChanged<String?> onProjectChanged;

  final RecordingFilter statusFilter;
  final Map<RecordingFilter, int> counts;
  final ValueChanged<RecordingFilter> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final double progress = total == 0 ? 0 : reviewed / total;
    final bool allHandedOff = total > 0 && reviewed == total;

    return Container(
      decoration: BoxDecoration(
        color: Console.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Console.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget search = QueueSearchField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  value: searchQuery,
                  onChanged: onSearchChanged,
                );
                final Widget segments = ReviewSegments(
                  total: total,
                  reviewed: reviewed,
                  filter: reviewFilter,
                  onChanged: onReviewChanged,
                );
                final Widget status = QueueStatusMenu(
                  selected: statusFilter,
                  counts: counts,
                  onSelected: onStatusChanged,
                );
                final Widget? project = projects.isEmpty
                    ? null
                    : QueueProjectFilter(
                        projects: projects,
                        selectedId: selectedProjectId,
                        onChanged: onProjectChanged,
                        compact: true,
                      );
                if (constraints.maxWidth >= singleLineWidth) {
                  return Row(
                    children: <Widget>[
                      // The only flex child: everything beside it is a control
                      // at its natural width, and the query field takes what is
                      // left rather than squeezing a count off the bar.
                      Expanded(child: search),
                      const SizedBox(width: 8),
                      segments,
                      const SizedBox(width: 8),
                      status,
                      if (project != null) ...<Widget>[
                        const SizedBox(width: 8),
                        SizedBox(width: _projectWidth, child: project),
                      ],
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(child: search),
                        const SizedBox(width: 8),
                        status,
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        // Scrolls rather than wraps: a segmented control that
                        // reflows onto two lines stops reading as one control.
                        Flexible(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: segments,
                          ),
                        ),
                        if (project != null) ...<Widget>[
                          const SizedBox(width: 8),
                          SizedBox(width: _projectWidth, child: project),
                        ],
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          // Full-bleed under the bar rather than inset inside it, so the line
          // reads as the bar's own edge filling up rather than as a widget
          // parked at the bottom of it.
          Semantics(
            label: 'Handed off $reviewed of $total captures',
            excludeSemantics: true,
            child: Tooltip(
              message: 'Handed off $reviewed of $total',
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: progress),
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double value, Widget? child) {
                  return LinearProgressIndicator(
                    value: value,
                    minHeight: 2,
                    color: allHandedOff ? Console.green : Console.accent,
                    backgroundColor: Console.track,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The five status buckets, as one button that names the active one.
///
/// A menu rather than the row of chips it replaces, and the trade is explicit:
/// four counts leave the bar. They are not lost — every item in the menu carries
/// its own — but the answer to "is anything failing" now costs a click where it
/// used to cost a glance. That is what buys the whole toolbar a single line, and
/// the failure case has a louder signal anyway: a failed capture renders a red
/// card with a RETRY button on it.
class QueueStatusMenu extends StatelessWidget {
  QueueStatusMenu({
    super.key,
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  final RecordingFilter selected;
  final Map<RecordingFilter, int> counts;
  final ValueChanged<RecordingFilter> onSelected;

  static String labelFor(RecordingFilter value) => value.name.toUpperCase();

  @override
  Widget build(BuildContext context) {
    final bool narrowed = selected != RecordingFilter.all;
    final Color foreground = narrowed ? Console.accent : Console.chipLabel;

    return PopupMenuButton<RecordingFilter>(
      tooltip: 'Filter by processing status',
      color: Console.surfaceRaised,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => RecordingFilter.values
          .map(
            (RecordingFilter value) => PopupMenuItem<RecordingFilter>(
              value: value,
              height: 38,
              child: Row(
                children: <Widget>[
                  // A tick rather than a highlighted row: the menu opens over a
                  // dark surface where a selected-row fill is easy to read as a
                  // hover state.
                  SizedBox(
                    width: 22,
                    child: value == selected
                        ? Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: Console.accent,
                          )
                        : null,
                  ),
                  Text(
                    '${labelFor(value)} ${counts[value] ?? 0}',
                    style: ConsoleText.chip.copyWith(
                      color: value == selected
                          ? Console.accent
                          : Console.textSoft,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: narrowed
              ? Console.accent.withValues(alpha: .12)
              : Console.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: narrowed ? Console.accent.withValues(alpha: .4) : Console.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${labelFor(selected)} ${counts[selected] ?? 0}',
              style: ConsoleText.chip.copyWith(color: foreground),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: foreground),
          ],
        ),
      ),
    );
  }
}

class QueueSearchField extends StatelessWidget {
  QueueSearchField({
    super.key,
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
      decoration: queueFieldDecoration.copyWith(
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
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
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

class QueueProjectFilter extends StatelessWidget {
  QueueProjectFilter({
    super.key,
    required this.projects,
    required this.selectedId,
    required this.onChanged,
    this.compact = false,
  });

  final List<Project> projects;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  /// Drops the floating label and adopts the search box's filled outline, so
  /// the two read as one control beside each other on the toolbar. The stacked
  /// layout on a phone keeps the label — there it has a row to itself and
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
      // toolbar, so the label has to be allowed to ellipsize. Without this the
      // dropdown's own row overflows — and it overflows while laying out the
      // *menu* items offstage, so the visible control looks correct and only the
      // debug stripes say otherwise.
      isExpanded: true,
      // Matched to the search box's 18 px prefix icon: the default 24 would
      // make the dropdown the taller of the two and break the line.
      iconSize: compact ? 18 : 24,
      style: compact ? TextStyle(color: Console.text, fontSize: 13) : null,
      decoration: compact
          ? queueFieldDecoration.copyWith(
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

/// The five status buckets as chips — the phone's filter panel, where the
/// toolbar's [QueueStatusMenu] would put a menu inside a disclosure the user
/// already opened to see filters.
class QueueStatusChips extends StatelessWidget {
  QueueStatusChips({
    super.key,
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
              label: QueueStatusMenu.labelFor(item),
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

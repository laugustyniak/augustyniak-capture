import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'queue_tab.dart';

/// The Queue's header on a phone: one dense strip carrying the review axis, with
/// search and the remaining filters folded behind their own buttons.
///
/// It replaces three stacked blocks — the page title, the progress strip and the
/// always-open search/chips row — that between them ate roughly a third of a
/// 393x852 screen before a single capture was drawn. Everything they carried is
/// still here:
///
/// - the **counts** moved onto the review segments (`DESK 4`), which is where
///   they are actionable. The `n / m` and its progress bar do not survive the
///   move, and deliberately: the same number is now on the segment the user taps
///   to act on it, and a bar that only ever restates a ratio is the vanity
///   metric `ReviewedStrip` was already written to avoid;
/// - **search** and the **status chips** are one tap away rather than on screen.
///
/// The disclosure has one rule and it is load-bearing: **a panel whose control
/// is engaged cannot be closed.** With the chips hidden, "empty because a filter
/// excludes everything" and "empty because there is nothing" become the same
/// picture — the exact failure the pinned strip was introduced to prevent. So
/// the caller passes `searchOpen`/`filtersOpen` already OR-ed with "is a query
/// typed" / "is a filter set", and the toggle button reads as active whenever
/// that is true.
///
/// It takes its two panels as built widgets rather than their inputs: the search
/// field, the status chips and the project selector are private to the tab, and
/// this widget's job is the chrome around them, not their content.
class CompactQueueHeader extends StatelessWidget {
  CompactQueueHeader({
    super.key,
    required this.total,
    required this.reviewed,
    required this.filter,
    required this.onFilterChanged,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.search,
    required this.filtersOpen,
    required this.onToggleFilters,
    required this.filters,
    this.onSync,
    this.isSyncing = false,
  });

  final int total;
  final int reviewed;
  final ReviewFilter filter;
  final ValueChanged<ReviewFilter> onFilterChanged;

  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final Widget search;

  final bool filtersOpen;
  final VoidCallback onToggleFilters;
  final Widget filters;

  final Future<void> Function()? onSync;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(bottom: BorderSide(color: Console.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Scrolls rather than wraps: three segments with counts do fit a
              // 393 px screen, but `OFF DESK 128` on a 320 px one does not, and
              // a segmented control that reflows onto two lines stops reading as
              // one control.
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _ReviewSegments(
                    total: total,
                    reviewed: reviewed,
                    filter: filter,
                    onChanged: onFilterChanged,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (onSync != null) ...<Widget>[
                _HeaderToggle(
                  child: SyncSpinIcon(isSyncing: isSyncing, size: 17),
                  active: isSyncing,
                  onTap: () async => onSync!(),
                  semanticLabel: 'Sync Turso Cloud',
                ),
                const SizedBox(width: 6),
              ],
              _HeaderToggle(
                icon: Icons.search_rounded,
                active: searchOpen,
                onTap: onToggleSearch,
                // Not "Search captures": that is the field's own hint, and a
                // semantics finder matching both is a test that cannot tap
                // either.
                semanticLabel: 'Toggle search',
              ),
              const SizedBox(width: 6),
              _HeaderToggle(
                icon: Icons.filter_list_rounded,
                active: filtersOpen,
                onTap: onToggleFilters,
                semanticLabel: 'Toggle filters',
              ),
            ],
          ),
          if (searchOpen)
            Padding(padding: const EdgeInsets.only(top: 8), child: search),
          if (filtersOpen)
            Padding(padding: const EdgeInsets.only(top: 10), child: filters),
        ],
      ),
    );
  }
}

/// `DESK 4 · OFF DESK 33 · ANY 37` as one segmented control.
///
/// A segmented control rather than the three [ConsoleChip]s the wide form uses:
/// these options are mutually exclusive and always exactly three, which is what
/// a segment says and a chip does not — and the shared track is what lets them
/// sit in a 34 px strip instead of a 44 px row of separate pills.
class _ReviewSegments extends StatelessWidget {
  _ReviewSegments({
    required this.total,
    required this.reviewed,
    required this.filter,
    required this.onChanged,
  });

  final int total;
  final int reviewed;
  final ReviewFilter filter;
  final ValueChanged<ReviewFilter> onChanged;

  /// Same words as [ReviewedStrip], which is the point: the phone and the
  /// desktop must not name the same axis differently.
  String _label(ReviewFilter value) => switch (value) {
    ReviewFilter.desk => 'DESK',
    ReviewFilter.handedOff => 'OFF DESK',
    ReviewFilter.all => 'ANY',
  };

  int _count(ReviewFilter value) => switch (value) {
    ReviewFilter.desk => total - reviewed,
    ReviewFilter.handedOff => reviewed,
    ReviewFilter.all => total,
  };

  /// The green is the same "you are finished with it" green the wide form uses
  /// on its OFF DESK chip and on the review tick.
  Color _color(ReviewFilter value) =>
      value == ReviewFilter.handedOff ? Console.green : Console.accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Console.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Console.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: ReviewFilter.values.map((ReviewFilter value) {
          final bool selected = filter == value;
          final Color color = _color(value);
          return Semantics(
            button: true,
            selected: selected,
            child: InkWell(
              onTap: () => onChanged(value),
              borderRadius: BorderRadius.circular(7),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                constraints: const BoxConstraints(minHeight: 34),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '${_label(value)} ${_count(value)}',
                  style: ConsoleText.chip.copyWith(
                    fontSize: 10,
                    letterSpacing: .5,
                    color: selected ? Console.ink : Console.muted,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// A 36 px square that opens one of the header's two panels.
class _HeaderToggle extends StatelessWidget {
  _HeaderToggle({
    this.icon,
    this.child,
    required this.active,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData? icon;
  final Widget? child;
  final bool active;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? Console.iconTile : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: active ? Console.accent : Console.border),
          ),
          child: Center(
            child: child ??
                Icon(
                  icon,
                  size: 17,
                  color: active ? Console.accent : Console.muted,
                ),
          ),
        ),
      ),
    );
  }
}

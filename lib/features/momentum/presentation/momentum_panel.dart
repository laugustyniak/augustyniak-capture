import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/momentum_snapshot.dart';
import 'momentum_controller.dart';

/// How much left the desk lately, and whether today has cleared its bar.
///
/// **Mounted on the Timer tab, above `SESSIONS DONE`, and laid out to match
/// it.** That tab is already the "how am I doing" destination, and the two
/// panels are two measures of one rhythm: sessions say how long the work went
/// on, closures say how much came out of it. Giving momentum a seventh
/// navigation destination would have added a second place to look for one
/// answer.
///
/// No `const` constructor here or on any private widget in this file. The
/// palette is mutable global state so the theme can swap at runtime, and
/// Flutter skips rebuilding a child `identical` to the previous one — a `const`
/// widget would keep painting the old theme after a swap, which is a correct
/// render of a stale widget and therefore invisible to every widget test.
class MomentumPanel extends StatefulWidget {
  MomentumPanel({super.key, required this.controller});

  final MomentumController controller;

  /// The two windows offered, matching `SESSIONS DONE` so the pair reads as one
  /// control rather than two conventions.
  static const List<int> windows = <int>[7, 30];

  @override
  State<MomentumPanel> createState() => _MomentumPanelState();
}

class _MomentumPanelState extends State<MomentumPanel> {
  int _days = MomentumPanel.windows.first;

  @override
  Widget build(BuildContext context) {
    final MomentumController momentum = widget.controller;

    // Three states, not two, and in this order. "Nothing closed yet" is a
    // positive claim about the user's own history, so it must not be made when
    // the file merely failed to read — the rule `_indexUnreadable` and
    // `historyUnreadable` both encode.
    if (momentum.historyUnreadable) {
      return ConsoleCard(
        accent: Console.amber.withValues(alpha: .45),
        child: Text(
          'The closure history could not be read, so this is not a count of '
          'nothing — it is no answer. Closed captures are still being '
          'appended; the Logs tab has the reason.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }
    if (!momentum.hasClosures) {
      return ConsoleCard(
        child: Text(
          'Nothing closed yet. A capture counts here when it leaves the desk — '
          'ticked off, routed to a project inbox, or handed to an agent.',
          style: ConsoleText.micro.copyWith(height: 1.45),
        ),
      );
    }

    final MomentumSnapshot snapshot = momentum.snapshot(days: _days);
    final List<ProjectClosures> projects = momentum.projectTallies(_days);
    final int inWindow = snapshot.days.fold(
      0,
      (int total, DayClosures day) => total + day.closures,
    );

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${snapshot.today}',
                style: TextStyle(
                  fontFamily: ConsoleFont.display,
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: snapshot.today == 0
                      ? Console.mutedSoft
                      : (snapshot.metTarget ? Console.green : Console.accent),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'closed today',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConsoleText.cardMeta,
                  ),
                ),
              ),
              Text(
                snapshot.metTarget
                    ? 'target ${snapshot.target} ✓'
                    : 'target ${snapshot.target}',
                maxLines: 1,
                style: ConsoleText.micro.copyWith(
                  color: snapshot.metTarget ? Console.green : Console.dimText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _PaceLine(snapshot: snapshot),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              for (final int days in MomentumPanel.windows) ...<Widget>[
                ConsoleChip(
                  label: '$days DAYS',
                  selected: days == _days,
                  onSelected: () => setState(() => _days = days),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  '$inWindow in $_days days',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.micro,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // A week is few enough rows to label each day and give it a bar; a
          // month is not, so it switches to a grid rather than stacking thirty
          // labelled rows — which overflows the card and is unreadable anyway.
          // Same split, at the same threshold, as `SESSIONS DONE`.
          if (_days <= 7)
            _ClosureBars(days: snapshot.days)
          else
            _ClosureGrid(days: snapshot.days),
          // Two conditions, each ruling out a different empty answer: with no
          // project on any closure the section is one full-width `No project`
          // bar, and with one row it restates the total above it in more words.
          if (projects.length > 1 &&
              projects.any(
                (ProjectClosures project) => project.projectId != null,
              )) ...<Widget>[
            const SizedBox(height: 18),
            Container(height: 1, color: Console.border),
            const SizedBox(height: 14),
            // `CLOSED BY PROJECT`, never `WHERE IT WENT` — that heading is
            // taken by the session split on this same tab, and two identical
            // headings describing different things is a genuine ambiguity.
            Text('CLOSED BY PROJECT', style: ConsoleText.pill),
            const SizedBox(height: 10),
            _ProjectClosureSplit(projects: projects),
          ],
        ],
      ),
    );
  }
}

/// The pace and its direction, or nothing when there is no baseline yet.
class _PaceLine extends StatelessWidget {
  _PaceLine({required this.snapshot});

  final MomentumSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final bool? rising = snapshot.rising;
    return Row(
      children: <Widget>[
        Text(
          'pace ${snapshot.pace.toStringAsFixed(1)}/day',
          style: ConsoleText.micro,
        ),
        // Omitted rather than drawn flat when there is nothing to compare: an
        // arrow that always points somewhere stops meaning anything.
        if (rising != null) ...<Widget>[
          const SizedBox(width: 6),
          Icon(
            rising ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 12,
            color: rising ? Console.green : Console.dimText,
          ),
        ],
      ],
    );
  }
}

/// One labelled row per day, bar proportional to the busiest day shown.
///
/// Days with nothing on them are drawn rather than skipped — an empty row is
/// the fact that nothing was finished, and a strip that omitted them would make
/// one busy Monday look like a steady week.
class _ClosureBars extends StatelessWidget {
  _ClosureBars({required this.days});

  final List<DayClosures> days;

  static const List<String> _names = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  @override
  Widget build(BuildContext context) {
    final int busiest = days.fold(
      1,
      (int peak, DayClosures day) => day.closures > peak ? day.closures : peak,
    );

    // Newest-first is right for a list of records, but a strip of days reads
    // left to right in time like every other calendar the user owns.
    final List<DayClosures> ordered = days.reversed.toList();

    return Column(
      children: <Widget>[
        for (final DayClosures day in ordered) ...<Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 34,
                child: Text(
                  _names[day.day.weekday - 1],
                  style: ConsoleText.micro.copyWith(
                    color: day.isEmpty ? Console.dimText : Console.textSoft,
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return Stack(
                      children: <Widget>[
                        Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: Console.track,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        if (!day.isEmpty)
                          Container(
                            height: 8,
                            width:
                                constraints.maxWidth * (day.closures / busiest),
                            decoration: BoxDecoration(
                              color: Console.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(
                width: 26,
                child: Text(
                  day.isEmpty ? '–' : '${day.closures}',
                  textAlign: TextAlign.right,
                  style: ConsoleText.micro.copyWith(
                    color: day.isEmpty ? Console.dimText : Console.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

/// The month view: one cell per day, oldest first, shaded by how many captures
/// that day closed.
///
/// **One hue, light to dark.** A closure count is a magnitude, so it takes a
/// sequential scale rather than a set of distinct colours — a rainbow here would
/// imply the days were different *kinds* of thing rather than more and less of
/// the same one. Empty days keep the track colour, so a gap is visibly a gap
/// and not a missing cell.
class _ClosureGrid extends StatelessWidget {
  _ClosureGrid({required this.days});

  final List<DayClosures> days;

  @override
  Widget build(BuildContext context) {
    final int busiest = days.fold(
      1,
      (int peak, DayClosures day) => day.closures > peak ? day.closures : peak,
    );
    final List<DayClosures> ordered = days.reversed.toList();

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        for (final DayClosures day in ordered)
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: day.isEmpty
                  ? Console.track
                  : Console.accent.withValues(
                      // Floored well above zero so a one-closure day is still
                      // visible against the empty track next to it.
                      alpha: .25 + .75 * (day.closures / busiest),
                    ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// Where the finished work was filed, busiest first.
class _ProjectClosureSplit extends StatelessWidget {
  _ProjectClosureSplit({required this.projects});

  final List<ProjectClosures> projects;

  /// Applied to **projects only**, so the unattributed residual is never the
  /// row that falls off the end.
  static const int maxRows = 5;

  @override
  Widget build(BuildContext context) {
    final List<ProjectClosures> named = projects
        .where((ProjectClosures project) => project.projectId != null)
        .toList();
    final List<ProjectClosures> shown = named.take(maxRows).toList();
    final int hidden = named.length - shown.length;
    final ProjectClosures? residual = projects
        .where((ProjectClosures project) => project.projectId == null)
        .firstOrNull;

    final int busiest = projects.fold(
      1,
      (int peak, ProjectClosures project) =>
          project.closures > peak ? project.closures : peak,
    );

    return Column(
      children: <Widget>[
        for (final ProjectClosures project in <ProjectClosures>[
          ...shown,
          ?residual,
        ]) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Text(
                  project.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.micro.copyWith(
                    color: project.projectId == null
                        ? Console.dimText
                        : Console.textSoft,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 5,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return Stack(
                      children: <Widget>[
                        Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: Console.track,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        Container(
                          height: 8,
                          width:
                              constraints.maxWidth *
                              (project.closures / busiest),
                          decoration: BoxDecoration(
                            color: project.projectId == null
                                ? Console.mutedSoft
                                : Console.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(
                width: 26,
                child: Text(
                  '${project.closures}',
                  textAlign: TextAlign.right,
                  style: ConsoleText.micro.copyWith(color: Console.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        // Named rather than silently dropped: a capped list that says nothing
        // reads as "that was all of it".
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '+$hidden more ${hidden == 1 ? 'project' : 'projects'}',
              style: ConsoleText.micro.copyWith(color: Console.dimText),
            ),
          ),
      ],
    );
  }
}

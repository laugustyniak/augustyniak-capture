import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// One destination in [ConsoleNavRail].
class RailDestination {
  const RailDestination({
    required this.icon,
    required this.label,
    this.count,
    this.warn = false,
    this.progress,
  });

  final IconData icon;
  final String label;

  /// Rendered right-aligned in mono. Null hides it — a destination with a bare
  /// `0` reads as broken, one with no count reads as a plain link.
  final int? count;

  /// Draws the amber dot the bottom navigation puts on Models while no provider
  /// profile is active, so "transcription is off" stays visible in both layouts.
  final bool warn;

  /// Drawn as a ring around the icon in the collapsed rail — the Queue's
  /// handed-off ratio, which the expanded rail prints as `CLEAR n / m`.
  final double? progress;
}

/// The design's 216 px left rail: wordmark, destinations, review progress and
/// the capture controls, in one column against the chrome colour.
///
/// It replaces the bottom [NavigationBar] above [Console.railBreakpoint] rather
/// than joining it — two simultaneous navigations would give the same five
/// destinations two different homes. The narrow layout keeps the bottom bar and
/// the floating `CaptureDock`; this is the wide counterpart of *both*, which is
/// why the record button lives down here rather than staying afloat over a
/// list that is now several columns wide.
class ConsoleNavRail extends StatelessWidget {
  const ConsoleNavRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.reviewed,
    required this.total,
    required this.onRecord,
    required this.onCapture,
    required this.busy,
    this.expanded = true,
    this.onToggleExpanded,
  });

  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Drives the `CLEAR n / m` strip. The phone layout carries the same two
  /// numbers on the review switch itself (`DESK 4 · OFF DESK 33`), which is why
  /// it no longer spends a row of the queue on a progress strip; the wide layout
  /// has a permanent column to hang them in and can afford both.
  final int reviewed;
  final int total;

  final VoidCallback onRecord;

  /// Opens the `+` sheet (note, audio/image/video upload).
  final VoidCallback onCapture;

  /// A capture is already running; both buttons go inert rather than
  /// disappearing, so the column does not resize under the pointer.
  final bool busy;

  /// Labels and the `CLEAR` strip at [Console.railWidth], or icons only at
  /// [Console.railCollapsedWidth]. The collapsed form gives the Queue's
  /// master list the 150 px the labels cost.
  final bool expanded;

  /// Null hides the toggle, which keeps the rail as it was for a host that
  /// does not persist the choice.
  final VoidCallback? onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    if (!expanded) return _buildCollapsed();
    return Container(
      width: Console.railWidth,
      decoration: BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(right: BorderSide(color: Console.track)),
      ),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Wordmark(),
              const SizedBox(height: 10),
              for (int i = 0; i < destinations.length; i++)
                _RailButton(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
              const Spacer(),
              if (onToggleExpanded != null) ...<Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ToggleButton(expanded: true, onTap: onToggleExpanded!),
                ),
                const SizedBox(height: 8),
              ],
              _ReviewProgress(reviewed: reviewed, total: total),
              const SizedBox(height: 10),
              _SecondaryButton(onTap: busy ? null : onCapture),
              const SizedBox(height: 8),
              _RecordButton(onTap: busy ? null : onRecord, busy: busy),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed() {
    return Container(
      width: Console.railCollapsedWidth,
      decoration: BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(right: BorderSide(color: Console.track)),
      ),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: <Widget>[
              _Monogram(),
              const SizedBox(height: 14),
              for (int i = 0; i < destinations.length; i++)
                _RailIconButton(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
              const Spacer(),
              if (onToggleExpanded != null)
                _ToggleButton(expanded: false, onTap: onToggleExpanded!),
              const SizedBox(height: 6),
              _RoundButton(
                tooltip: 'Note / upload',
                semanticLabel: 'New note or upload',
                onTap: busy ? null : onCapture,
                child: Icon(
                  Icons.add_rounded,
                  size: 20,
                  color: busy ? Console.dim : Console.mutedSoft,
                ),
              ),
              const SizedBox(height: 8),
              _RoundButton(
                tooltip: 'Record',
                semanticLabel: busy ? 'Saving capture' : 'Start recording',
                filled: !busy,
                onTap: busy ? null : onRecord,
                child: busy
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Console.accent,
                        ),
                      )
                    : Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Console.ink,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The wordmark's tile on its own, for the collapsed rail.
class _Monogram extends StatelessWidget {
  _Monogram();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Console.accentDeep, Console.accent],
        ),
      ),
      child: Text(
        'A',
        style: TextStyle(
          fontFamily: ConsoleFont.display,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Console.ink,
        ),
      ),
    );
  }
}

/// `231`, `3k` — a count that has to fit a 44 px button's corner.
String _compactCount(int value) =>
    value < 1000 ? '$value' : '${(value / 1000).floor()}k';

class _RailIconButton extends StatelessWidget {
  _RailIconButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double? progress = destination.progress;
    return Tooltip(
      message: destination.label,
      waitDuration: const Duration(milliseconds: 300),
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.count == null
            ? destination.label
            : '${destination.label}, ${destination.count}',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: selected
                    ? Console.accent.withValues(alpha: .15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: <Widget>[
                  if (progress != null)
                    SizedBox.square(
                      dimension: 34,
                      child: CircularProgressIndicator(
                        value: progress.clamp(0, 1),
                        strokeWidth: 2,
                        color: progress >= 1 ? Console.green : Console.accent,
                        backgroundColor: Console.track,
                      ),
                    ),
                  Icon(
                    destination.icon,
                    size: progress != null ? 16 : 20,
                    color: selected ? Console.accent : Console.muted,
                  ),
                  if (destination.count != null)
                    Positioned(
                      top: 1,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Console.surfaceRaised,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _compactCount(destination.count!),
                          style: ConsoleText.micro.copyWith(
                            fontSize: 9,
                            color: Console.dimText,
                          ),
                        ),
                      ),
                    ),
                  if (destination.warn)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Console.amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  _RoundButton({
    required this.tooltip,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.filled = false,
  });

  final String tooltip;
  final String semanticLabel;
  final VoidCallback? onTap;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? Console.accent : Console.surface,
              border: filled ? null : Border.all(color: Console.border),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  _ToggleButton({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String label = expanded ? 'Collapse sidebar' : 'Expand sidebar';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: 44,
            child: Icon(
              expanded
                  ? Icons.keyboard_double_arrow_left_rounded
                  : Icons.keyboard_double_arrow_right_rounded,
              size: 18,
              color: Console.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The product mark. Two lines because the identity is two things: the tool is
/// `CAPTURE`, the publisher is `augustyniak` — the same split the eyebrow makes
/// in the narrow layout's `ConsoleHeader`.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Console.accentDeep, Console.accent],
              ),
            ),
            child: Text(
              'A',
              style: TextStyle(
                fontFamily: ConsoleFont.display,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Console.ink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'CAPTURE',
                style: ConsoleText.eyebrow.copyWith(
                  fontFamily: ConsoleFont.display,
                  fontSize: 13,
                  letterSpacing: .8,
                  color: Console.text,
                ),
              ),
              Text(
                'augustyniak',
                style: ConsoleText.micro,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Console.text : Console.muted;
    final Widget icon = Icon(
      destination.icon,
      size: 16,
      color: selected ? Console.accent : Console.muted,
    );

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Console.surfaceRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 18,
                child: destination.warn
                    ? Badge(
                        backgroundColor: Console.amber,
                        smallSize: 6,
                        child: icon,
                      )
                    : icon,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  destination.label,
                  style: ConsoleText.railLabel.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (destination.count != null)
                Text(
                  '${destination.count}',
                  style: ConsoleText.micro.copyWith(
                    // dimText, not dim: this carries a number the user reads.
                    // `dim` is the non-text tint and sits below the 4.5:1 floor.
                    color: selected ? Console.accent : Console.dimText,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `CLEAR 33 / 36 · 92%` over a 3 px bar — the user-owned axis, stated as a
/// goal.
///
/// `CLEAR` rather than the chips' `OFF DESK`: this row carries the percentage
/// too, and at [ConsoleText.micro]'s letter spacing the longer label overflows
/// the 184 px the rail leaves by 21 px. Same image at the length that fits —
/// the empty panel says "Desk clear" in full.
class _ReviewProgress extends StatelessWidget {
  const _ReviewProgress({required this.reviewed, required this.total});

  final int reviewed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final double progress = total == 0 ? 0 : reviewed / total;
    final bool complete = total > 0 && reviewed == total;

    return Semantics(
      label: 'Handed off $reviewed of $total captures',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  'CLEAR $reviewed / $total',
                  style: ConsoleText.micro.copyWith(fontSize: 10.5),
                ),
                Text(
                  // Rounded down, so `99%` never appears on an unfinished queue
                  // and `100%` means exactly that.
                  '${(progress * 100).floor()}%',
                  style: ConsoleText.micro.copyWith(
                    fontSize: 10.5,
                    color: complete ? Console.green : Console.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: progress),
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double value, Widget? _) {
                  return LinearProgressIndicator(
                    value: value,
                    minHeight: 3,
                    color: complete ? Console.green : Console.accent,
                    backgroundColor: Console.track,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Notes and uploads. Quiet on purpose: it sits directly above the one filled
/// control on the screen, and two gradients in a column would make neither of
/// them the obvious one.
class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New note or upload',
      // Unlike the compact bar's bare disc, this button spells its action out
      // on screen as well. Without this the two merge and a screen reader
      // announces one action twice, as "New note or upload NOTE / UPLOAD".
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Console.border),
            color: Console.surface,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.add_rounded,
                size: 15,
                color: onTap == null ? Console.dim : Console.mutedSoft,
              ),
              const SizedBox(width: 7),
              Text(
                'NOTE / UPLOAD',
                style: ConsoleText.chip.copyWith(
                  color: onTap == null ? Console.dim : Console.mutedSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one accented control in the whole shell.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onTap, required this.busy});

  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: busy ? 'Saving capture' : 'Start recording',
      // Same reason as the button above: the visible `RECORD` would otherwise
      // be appended to the spoken label.
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: busy
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Console.accentDeep, Console.accent],
                  ),
            color: busy ? Console.surfaceRaised : null,
            boxShadow: busy
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: Console.accent.withValues(alpha: .28),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: busy
              ? SizedBox(
                  height: 15,
                  child: Center(
                    child: SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Console.accent,
                      ),
                    ),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.fiber_manual_record_rounded,
                      size: 13,
                      color: Console.ink,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'RECORD',
                      style: ConsoleText.chip.copyWith(
                        fontFamily: ConsoleFont.display,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .5,
                        color: Console.ink,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

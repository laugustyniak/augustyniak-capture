import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// One destination in [ConsoleNavRail].
class RailDestination {
  const RailDestination({
    required this.icon,
    required this.label,
    this.count,
    this.warn = false,
  });

  final IconData icon;
  final String label;

  /// Rendered right-aligned in mono. Null hides it — a destination with a bare
  /// `0` reads as broken, one with no count reads as a plain link.
  final int? count;

  /// Draws the amber dot the bottom navigation puts on Models while no provider
  /// profile is active, so "transcription is off" stays visible in both layouts.
  final bool warn;
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
  });

  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Drives the `DONE n / m` strip. The phone layout carries the same two
  /// numbers on the review switch itself (`INBOX 4 · DONE 33`), which is why it
  /// no longer spends a row of the queue on a progress strip; the wide layout
  /// has a permanent column to hang them in and can afford both.
  final int reviewed;
  final int total;

  final VoidCallback onRecord;

  /// Opens the `+` sheet (note, audio/image/video upload).
  final VoidCallback onCapture;

  /// A capture is already running; both buttons go inert rather than
  /// disappearing, so the column does not resize under the pointer.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Console.railWidth,
      decoration: const BoxDecoration(
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
              const _Wordmark(),
              const SizedBox(height: 10),
              for (int i = 0; i < destinations.length; i++)
                _RailButton(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
              const Spacer(),
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
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Console.cyanDeep, Console.cyan],
              ),
            ),
            child: const Text(
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
                style: ConsoleText.micro.copyWith(fontSize: 10),
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
      color: selected ? Console.cyan : Console.muted,
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
                    fontSize: 10,
                    // dimText, not dim: this carries a number the user reads.
                    // `dim` is the non-text tint and sits below the 4.5:1 floor.
                    color: selected ? Console.cyan : Console.dimText,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `DONE 33 / 36 · 92%` over a 3 px bar — the user-owned axis, stated as a goal.
class _ReviewProgress extends StatelessWidget {
  const _ReviewProgress({required this.reviewed, required this.total});

  final int reviewed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final double progress = total == 0 ? 0 : reviewed / total;
    final bool complete = total > 0 && reviewed == total;

    return Semantics(
      label: 'Done $reviewed of $total captures',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  'DONE $reviewed / $total',
                  style: ConsoleText.micro.copyWith(fontSize: 10.5),
                ),
                Text(
                  // Rounded down, so `99%` never appears on an unfinished queue
                  // and `100%` means exactly that.
                  '${(progress * 100).floor()}%',
                  style: ConsoleText.micro.copyWith(
                    fontSize: 10.5,
                    color: complete ? Console.green : Console.cyan,
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
                    color: complete ? Console.green : Console.cyan,
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
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Console.cyanDeep, Console.cyan],
                  ),
            color: busy ? Console.surfaceRaised : null,
            boxShadow: busy
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: Console.cyan.withValues(alpha: .28),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: busy
              ? const SizedBox(
                  height: 15,
                  child: Center(
                    child: SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Console.cyan,
                      ),
                    ),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(
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

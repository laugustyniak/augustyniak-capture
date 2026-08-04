import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import 'recordings_controller.dart';

/// One destination in [CaptureNavBar].
class NavBarDestination {
  const NavBarDestination({
    required this.icon,
    required this.label,
    this.warn = false,
  });

  final IconData icon;

  /// The shell's own destination label. Five of them plus a 52 px disc fit a
  /// 393 px screen at 8 px mono, so they are not abbreviated — the bar shows
  /// the same words the rail does.
  final String label;

  /// Amber dot, for the Models tab while no provider profile is active.
  final bool warn;
}

/// The phone layout's bottom bar: navigation and the record button in **one**
/// row, from the mobile design.
///
/// It replaces two separate things — Material's `NavigationBar` and the
/// floating `CaptureDock` that used to hover above it. That pairing cost 66 px
/// of bar plus a 90 px scrim plus a 64 px disc, on the axis a phone has least
/// of; and the disc, being centred, sat on top of whichever card happened to be
/// under it. Merging them puts the one thing this app is for at the end of the
/// row where a thumb already is.
///
/// Note/upload is deliberately **not** here. It lives in the Queue's own header
/// beside the search and filter toggles, because a second disc in this row
/// would make neither of the two the obvious one — and typing a note is not the
/// action the app is opened to perform.
class CaptureNavBar extends StatelessWidget {
  const CaptureNavBar({
    super.key,
    required this.controller,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final RecordingsController controller;
  final List<NavBarDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final bool busy = controller.isBusy;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(top: BorderSide(color: Console.track)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < destinations.length; i++)
                Expanded(
                  child: _NavItem(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                ),
              const SizedBox(width: 6),
              _RecordButton(
                busy: busy,
                onTap: busy ? null : controller.startRecording,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavBarDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? Console.cyan : Console.dim;
    final Widget icon = Icon(destination.icon, size: 18, color: color);

    return Semantics(
      button: true,
      selected: selected,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: ConstrainedBox(
          // Material's own minimum touch target. The row is shorter than the
          // 66 px `NavigationBar` it replaced, but never below this.
          constraints: const BoxConstraints(minHeight: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              destination.warn
                  ? Badge(
                      backgroundColor: Console.amber,
                      smallSize: 6,
                      child: icon,
                    )
                  : icon,
              const SizedBox(height: 3),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: ConsoleText.navLabel.copyWith(
                  fontSize: 8,
                  letterSpacing: 1,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 52 px cyan disc. Starting a recording swaps the whole screen for the
/// capture view, so this button only ever has to say "start" — the stop and
/// save affordance lives there, where it cannot be mistaken for anything else.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: busy ? 'Saving capture' : 'Start recording',
      child: InkResponse(
        onTap: onTap,
        radius: 34,
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: busy
                ? null
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Console.cyanDeep, Console.cyanBright],
                  ),
            color: busy ? Console.surfaceRaised : null,
            boxShadow: busy
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: Console.cyanBright.withValues(alpha: .35),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Console.cyan,
                  ),
                )
              : const Icon(
                  Icons.mic_none_rounded,
                  size: 22,
                  color: Console.ink,
                ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';

/// One destination in the compact phone navigation bar.
class CaptureNavDestination {
  const CaptureNavDestination({
    required this.icon,
    required this.label,
    required this.shortLabel,
    this.warn = false,
  });

  final IconData icon;

  /// Full destination name used by assistive technology.
  final String label;

  /// Visible label sized for five destinations beside the capture controls.
  final String shortLabel;

  /// Shows an amber status dot, currently used when Models is unconfigured.
  final bool warn;
}

/// Compact phone bar combining navigation with the primary capture actions.
///
/// Desktop keeps the existing Material navigation and floating capture dock.
/// On a phone, putting these actions in one 56 px row returns the vertical space
/// previously occupied by both a 66 px navigation bar and the dock's scrim.
class CaptureNavBar extends StatelessWidget {
  const CaptureNavBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.busy,
    required this.onRecord,
    required this.onOpenCaptureMenu,
  });

  final List<CaptureNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool busy;
  final VoidCallback onRecord;
  final VoidCallback onOpenCaptureMenu;

  @override
  Widget build(BuildContext context) {
    assert(destinations.isNotEmpty);
    assert(selectedIndex >= 0 && selectedIndex < destinations.length);

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Console.surfaceDeep,
        border: Border(top: BorderSide(color: Console.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              const double fixedActionsWidth = 44 + 4 + 52 + 4;
              final double sharedWidth =
                  (constraints.maxWidth - fixedActionsWidth) /
                  destinations.length;
              final double navigationWidth = sharedWidth < 44
                  ? 44
                  : sharedWidth;

              // Only destinations scroll at unusually narrow widths. Capture
              // actions stay fixed and immediately reachable on every phone.
              return Row(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          for (
                            int index = 0;
                            index < destinations.length;
                            index++
                          )
                            SizedBox(
                              width: navigationWidth,
                              child: _NavigationItem(
                                destination: destinations[index],
                                selected: index == selectedIndex,
                                onTap: () => onSelected(index),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _CaptureButton(
                    icon: Icons.add_rounded,
                    label: 'New note or upload',
                    onTap: onOpenCaptureMenu,
                  ),
                  const SizedBox(width: 4),
                  _RecordButton(busy: busy, onTap: busy ? null : onRecord),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final CaptureNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? Console.cyan : Console.dimText;
    final Widget icon = Icon(destination.icon, size: 18, color: color);

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
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
                destination.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: ConsoleText.navLabel.copyWith(
                  fontSize: 8,
                  letterSpacing: .8,
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

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: 44,
          child: Icon(icon, size: 19, color: Console.dimText),
        ),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !busy,
      label: busy ? 'Saving capture' : 'Start recording',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy ? Console.surfaceRaised : Console.cyan,
            boxShadow: busy
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: Console.cyan.withValues(alpha: .35),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
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

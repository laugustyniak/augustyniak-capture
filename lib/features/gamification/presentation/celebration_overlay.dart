import 'dart:async';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/milestone.dart';
import 'confetti_particle.dart';
import 'gamification_controller.dart';
import 'milestone_copy.dart';

/// No `const` constructor, and that is a rule rather than an oversight.
///
/// This widget paints palette colours (`Console.surface`, `.scrim`, `.ink`,
/// `.muted`), and the palette is mutable global state so the theme can swap at
/// runtime without threading a `BuildContext` through every call site. Flutter
/// skips rebuilding a child that is `identical` to the previous one, so a
/// `const` instance would keep painting the old theme after a swap — a correct
/// render of a stale widget, which no widget test can see. `test/theme_test.dart`
/// scans for this; the sibling animation widgets keep their `const` because they
/// paint their own literal colours and never read the palette.
class CelebrationOverlay extends StatefulWidget {
  CelebrationOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final GamificationController controller;
  final Widget child;

  @override
  State<CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<CelebrationOverlay>
    with SingleTickerProviderStateMixin {
  Milestone? _currentMilestone;
  late AnimationController _animController;

  /// Built once, here, rather than inside the `AnimatedBuilder`.
  ///
  /// A `CurvedAnimation` created in a builder is constructed afresh on **every
  /// frame** of the animation and never disposed — sixty allocations a second
  /// that each hold a listener on the controller. Flutter reports the survivors
  /// as leaked animation objects.
  late final Animation<double> _fade;
  late final Animation<double> _pop;

  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fade = CurvedAnimation(parent: _animController, curve: Curves.easeInOut);
    _pop = CurvedAnimation(parent: _animController, curve: Curves.elasticOut);
    widget.controller.addListener(_onControllerChanged);
    _checkPending();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    // Before the controller they are parented to: a curve outliving its parent
    // is the leak this ordering exists to avoid.
    (_fade as CurvedAnimation).dispose();
    (_pop as CurvedAnimation).dispose();
    _animController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _checkPending();
  }

  void _checkPending() {
    final Milestone? pending = widget.controller.pendingMilestone;
    if (pending != _currentMilestone) {
      setState(() {
        _currentMilestone = pending;
      });

      _autoDismissTimer?.cancel();

      if (pending != null) {
        _animController.forward(from: 0.0);
        _autoDismissTimer = Timer(const Duration(seconds: 5), () {
          _dismiss();
        });
      } else {
        _animController.reverse();
      }
    }
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    _animController.reverse().then((_) {
      if (mounted) {
        widget.controller.dismissMilestone();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final Milestone? milestone = _currentMilestone;
    final copy = milestone == null ? null : milestoneCopyFor(milestone);

    return Stack(
      children: <Widget>[
        widget.child,
        if (copy != null) ...<Widget>[
          const Positioned.fill(child: ConfettiShowerWidget()),
          Positioned.fill(
            // **The overlay's own `Material`, and it is not decoration.** This
            // layer is a *sibling* of `widget.child`, not a descendant, so the
            // `Scaffold` inside that child is not an ancestor of anything here.
            // Without a `Material` above them, every `Text` below renders with
            // Flutter's yellow double underline — its way of reporting that it
            // has no `Material` to take default text styling from. The overlay
            // shipped looking broken for exactly this reason.
            //
            // `transparency` rather than `canvas`: the scrim below paints the
            // background, and a second opaque layer would hide the page the
            // overlay is meant to dim rather than replace.
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedBuilder(
                animation: _animController,
                builder: (BuildContext context, Widget? child) {
                  final double opacity = _fade.value;
                  final double scale = _pop.value.clamp(0.0, 1.2);

                  return Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: GestureDetector(
                      onTap: _dismiss,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        color: Console.scrim,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(24),
                        child: Transform.scale(
                          scale: scale == 0 ? 0.001 : scale,
                          child: GestureDetector(
                            onTap: () {}, // Prevent tap through to backdrop
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 380),
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: Console.surface,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: copy.color.withValues(alpha: 0.6),
                                  width: 2,
                                ),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: copy.color.withValues(alpha: 0.35),
                                    blurRadius: 24,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Container(
                                    width: 72,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: copy.color.withValues(alpha: 0.15),
                                      border: Border.all(
                                        color: copy.color,
                                        width: 2,
                                      ),
                                    ),
                                    child: Icon(
                                      copy.icon,
                                      size: 38,
                                      color: copy.color,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    copy.title,
                                    textAlign: TextAlign.center,
                                    style: ConsoleText.cardTitle.copyWith(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Console.text,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    copy.description,
                                    textAlign: TextAlign.center,
                                    style: ConsoleText.body.copyWith(
                                      color: Console.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: _dismiss,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: copy.color,
                                        // The token for anything drawn *on* an
                                        // accent fill — the same one the record
                                        // disc uses for its microphone. It flips
                                        // with the theme, which a hard-coded
                                        // white cannot: the light accents are
                                        // dark enough to need light text, and the
                                        // dark palette's are light enough to need
                                        // the opposite.
                                        foregroundColor: Console.ink,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        'AWESOME!',
                                        style: ConsoleText.chip.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Console.ink,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';

import '../../../app/ui_kit.dart';
import '../domain/milestone.dart';
import 'confetti_particle.dart';
import 'gamification_controller.dart';

class CelebrationOverlay extends StatefulWidget {
  const CelebrationOverlay({
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
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    widget.controller.addListener(_onControllerChanged);
    _checkPending();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
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
    return Stack(
      children: <Widget>[
        widget.child,
        if (_currentMilestone != null) ...<Widget>[
          const Positioned.fill(child: ConfettiShowerWidget()),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _animController,
              builder: (BuildContext context, Widget? child) {
                final double opacity = CurvedAnimation(
                  parent: _animController,
                  curve: Curves.easeInOut,
                ).value;
                final double scale = CurvedAnimation(
                  parent: _animController,
                  curve: Curves.elasticOut,
                ).value.clamp(0.0, 1.2);

                return Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: GestureDetector(
                    onTap: _dismiss,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      color: Colors.black45,
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
                                color: _currentMilestone!.color.withValues(alpha: 0.6),
                                width: 2,
                              ),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: _currentMilestone!.color.withValues(alpha: 0.35),
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
                                    color: _currentMilestone!.color.withValues(alpha: 0.15),
                                    border: Border.all(
                                      color: _currentMilestone!.color,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(
                                    _currentMilestone!.icon,
                                    size: 38,
                                    color: _currentMilestone!.color,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _currentMilestone!.title,
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
                                  _currentMilestone!.description,
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
                                      backgroundColor: _currentMilestone!.color,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: Text(
                                      'WSPANIALE!',
                                      style: ConsoleText.chip.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
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
        ],
      ],
    );
  }
}

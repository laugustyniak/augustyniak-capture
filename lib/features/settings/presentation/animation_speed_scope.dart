import 'package:flutter/widgets.dart';

import '../domain/animation_speed.dart';

/// Carries the chosen [AnimationSpeed] to every processing scene.
///
/// Installed in `MaterialApp.builder`, above the navigator, because the scene
/// also runs inside pushed routes (the focus view, the recording screen) that
/// an inherited widget under `RecordingsPage` would never reach.
class AnimationSpeedScope extends InheritedWidget {
  const AnimationSpeedScope({
    super.key,
    required this.speed,
    required super.child,
  });

  final AnimationSpeed speed;

  /// [AnimationSpeed.calm] where no scope is installed (most widget tests), so
  /// a scene renders at the same speed it would on a fresh install.
  static AnimationSpeed of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AnimationSpeedScope>()
          ?.speed ??
      AnimationSpeed.calm;

  @override
  bool updateShouldNotify(AnimationSpeedScope oldWidget) =>
      speed != oldWidget.speed;
}

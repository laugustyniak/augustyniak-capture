import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guards for the celebration overlay.
///
/// **A source scan rather than a widget test, and the reason is worth writing
/// down.** Raising the overlay means unlocking a milestone, which means
/// `GamificationController.initialize()`, which reaches `path_provider`. In a
/// `testWidgets` zone with no mock for that channel the future never completes
/// — the test hangs rather than failing, and `flutter test` still exits 0 on a
/// "did not complete". The same trap `ProjectContextReader` is written around.
///
/// Mocking the channel would buy a real render, and is worth doing the day this
/// overlay grows behaviour worth asserting. Until then these three checks pin
/// the three defects that actually shipped, at a cost of nothing.
void main() {
  late String source;

  setUp(() {
    source = File(
      'lib/features/gamification/presentation/celebration_overlay.dart',
    ).readAsStringSync();
  });

  test('the overlay layer carries its own Material', () {
    // **The defect this file exists for.** The overlay puts its celebration
    // layer in a `Stack` *beside* `widget.child`, so the `Scaffold` inside that
    // child is a sibling and not an ancestor. With no `Material` above them,
    // every `Text` in the overlay rendered with Flutter's yellow double
    // underline — its way of reporting that it has no `Material` to take
    // default text styling from. It shipped that way, and only looking at the
    // screen could have found it.
    expect(
      source,
      contains('MaterialType.transparency'),
      reason:
          'Without a Material ancestor the overlay text renders with a yellow '
          'double underline. `transparency` rather than `canvas`, so the scrim '
          'below still shows the dimmed page.',
    );
  });

  test('no CurvedAnimation is constructed inside a builder', () {
    // A `CurvedAnimation` built in an `AnimatedBuilder` callback is constructed
    // afresh on every frame and never disposed — roughly sixty leaked objects a
    // second, each holding a listener on the controller. They belong in
    // `initState`, disposed before the controller they are parented to.
    final int builderStart = source.indexOf('builder: (BuildContext context');
    expect(builderStart, greaterThan(-1));

    expect(
      source.substring(builderStart).contains('CurvedAnimation('),
      isFalse,
      reason:
          'Construct the curves once in initState and dispose them; a builder '
          'runs per frame.',
    );
    expect(source.contains('_fade'), isTrue);
    expect(source.contains('_pop'), isTrue);
  });

  test('the overlay paints from the palette, never raw Material colours', () {
    // Raw Material colours do not move when the theme does. The scrim has its
    // own token because `Console.shadow` is 10 % ink in the light palette —
    // invisible as a full-screen dim.
    //
    // Note this scans the whole file, comments included, so a comment quoting
    // one of these literals trips it. That is a real limitation of a text scan
    // and it caught its own doc comment once; the fix is to describe the colour
    // rather than name it.
    expect(
      source.contains('Colors.black45'),
      isFalse,
      reason: 'Use Console.scrim.',
    );
    expect(
      source.contains('Colors.white'),
      isFalse,
      reason: 'Use Console.ink — the token for anything on an accent fill.',
    );
    expect(source, contains('Console.scrim'));
  });

  test('the overlay has no const constructor', () {
    // It paints palette colours, and the palette is mutable global state so the
    // theme can swap at runtime. Flutter skips rebuilding a child `identical`
    // to the previous one, so a const instance would keep painting the old
    // theme — a correct render of a stale widget, invisible to every test.
    expect(
      source.contains('const CelebrationOverlay({'),
      isFalse,
      reason:
          'A widget that reads Console.* must not offer a const constructor.',
    );
  });
}

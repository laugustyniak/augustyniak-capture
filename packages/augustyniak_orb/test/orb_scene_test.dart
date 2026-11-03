import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({bool paused = false, double startSeconds = 0}) => Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox(
    width: 200,
    height: 200,
    child: OrbScene(
      key: const Key('orb'),
      preset: OrbPreset.defaults,
      paused: paused,
      startSeconds: startSeconds,
    ),
  ),
);

double _seconds(WidgetTester tester) =>
    (tester.state(find.byKey(const Key('orb'))) as dynamic).debugSeconds
        as double;

void main() {
  testWidgets('clock advances, freezes while paused, resumes where it left', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    final double running = _seconds(tester);
    expect(running, greaterThan(0));

    await tester.pumpWidget(_host(paused: true));
    final double frozen = _seconds(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_seconds(tester), frozen);

    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 500));
    expect(_seconds(tester), greaterThan(frozen));
    expect(_seconds(tester), lessThan(frozen + 0.6));
  });

  testWidgets('startSeconds seeds the clock', (WidgetTester tester) async {
    await tester.pumpWidget(_host(paused: true, startSeconds: 2.16));
    expect(_seconds(tester), 2.16);
  });

  testWidgets('a new startSeconds while paused re-seeds the clock', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(_host(paused: true, startSeconds: 2.16));
    expect(_seconds(tester), 2.16);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_seconds(tester), 2.16);
  });
}

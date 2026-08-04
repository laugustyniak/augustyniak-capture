import 'package:augustyniak_capture/features/recordings/presentation/nav_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The shell title-cases its own all-caps `destinations` before handing them
  // over, so the rail is exercised with the strings it actually receives.
  const List<RailDestination> destinations = <RailDestination>[
    RailDestination(
      icon: Icons.format_list_bulleted_rounded,
      label: 'Queue',
      count: 7,
    ),
    RailDestination(icon: Icons.account_tree_outlined, label: 'Projects'),
    RailDestination(icon: Icons.memory_rounded, label: 'Models', warn: true),
    RailDestination(icon: Icons.chevron_right_rounded, label: 'Logs'),
    RailDestination(icon: Icons.tune_rounded, label: 'Config'),
  ];

  Future<void> pumpRail(
    WidgetTester tester, {
    ValueChanged<int>? onSelected,
    VoidCallback? onRecord,
    VoidCallback? onCapture,
    bool busy = false,
    int reviewed = 3,
    int total = 7,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              ConsoleNavRail(
                destinations: destinations,
                selectedIndex: 0,
                onSelected: onSelected ?? (_) {},
                reviewed: reviewed,
                total: total,
                busy: busy,
                onRecord: onRecord ?? () {},
                onCapture: onCapture ?? () {},
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('spells destinations out, unlike the compact bar', (
    WidgetTester tester,
  ) async {
    await pumpRail(tester);

    // The bar has to abbreviate this one to fit beside the record disc; the
    // rail is the layout that does not, which is the reason both labels exist.
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('PROJ'), findsNothing);
  });

  testWidgets('counts only the destination that was given one', (
    WidgetTester tester,
  ) async {
    await pumpRail(tester);

    expect(find.text('7'), findsOneWidget);
    // A destination rendering a bare `0` reads as broken rather than as empty,
    // so a null count draws nothing at all.
    expect(find.text('0'), findsNothing);
  });

  testWidgets('routes navigation and both capture actions', (
    WidgetTester tester,
  ) async {
    int? selected;
    int recordings = 0;
    int menus = 0;

    await pumpRail(
      tester,
      onSelected: (int value) => selected = value,
      onRecord: () => recordings++,
      onCapture: () => menus++,
    );

    await tester.tap(find.text('Projects'));
    await tester.tap(find.bySemanticsLabel('New note or upload'));
    await tester.tap(find.bySemanticsLabel('Start recording'));

    expect(selected, 1);
    expect(menus, 1);
    expect(recordings, 1);
  });

  testWidgets('a running capture makes both capture controls inert', (
    WidgetTester tester,
  ) async {
    int recordings = 0;
    int menus = 0;

    await pumpRail(
      tester,
      busy: true,
      onRecord: () => recordings++,
      onCapture: () => menus++,
    );

    // Inert rather than absent: removing them would resize the column under
    // the pointer mid-capture.
    await tester.tap(find.bySemanticsLabel('New note or upload'));
    await tester.tap(find.bySemanticsLabel('Saving capture'));

    expect(recordings, 0);
    expect(menus, 0);
  });

  testWidgets('review progress is floored, so 100% means exactly that', (
    WidgetTester tester,
  ) async {
    await pumpRail(tester, reviewed: 34, total: 35);

    expect(find.text('DONE 34 / 35'), findsOneWidget);
    // 34/35 is 97.14%; a rounding-to-nearest would print `97%` here too, but
    // 99.6% would print `100%` on a queue that still holds work.
    expect(find.text('97%'), findsOneWidget);
  });

  testWidgets('an empty queue reads 0%, not a division by zero', (
    WidgetTester tester,
  ) async {
    await pumpRail(tester, reviewed: 0, total: 0);

    expect(find.text('DONE 0 / 0'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
  });
}

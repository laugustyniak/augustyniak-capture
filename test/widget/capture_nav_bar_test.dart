import 'package:augustyniak_capture/features/recordings/presentation/capture_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<CaptureNavDestination> destinations = <CaptureNavDestination>[
    CaptureNavDestination(
      icon: Icons.format_list_bulleted_rounded,
      label: 'QUEUE',
      shortLabel: 'QUEUE',
    ),
    CaptureNavDestination(
      icon: Icons.account_tree_outlined,
      label: 'PROJECTS',
      shortLabel: 'PROJ',
    ),
    CaptureNavDestination(
      icon: Icons.memory_rounded,
      label: 'MODELS',
      shortLabel: 'MODELS',
    ),
    CaptureNavDestination(
      icon: Icons.chevron_right_rounded,
      label: 'LOGS',
      shortLabel: 'LOGS',
    ),
    CaptureNavDestination(
      icon: Icons.tune_rounded,
      label: 'CONFIG',
      shortLabel: 'CONFIG',
    ),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    required ValueChanged<int> onSelected,
    required VoidCallback onRecord,
    required VoidCallback onOpenCaptureMenu,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CaptureNavBar(
            destinations: destinations,
            selectedIndex: 0,
            onSelected: onSelected,
            busy: false,
            onRecord: onRecord,
            onOpenCaptureMenu: onOpenCaptureMenu,
          ),
        ),
      ),
    );
  }

  testWidgets('uses compact labels without shortening semantics', (
    WidgetTester tester,
  ) async {
    await pumpBar(
      tester,
      onSelected: (_) {},
      onRecord: () {},
      onOpenCaptureMenu: () {},
    );

    expect(find.text('PROJ'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.bySemanticsLabel('PROJECTS'), findsOneWidget);
  });

  testWidgets('routes navigation and both capture actions', (
    WidgetTester tester,
  ) async {
    int? selected;
    int recordings = 0;
    int menus = 0;
    await pumpBar(
      tester,
      onSelected: (int value) => selected = value,
      onRecord: () => recordings++,
      onOpenCaptureMenu: () => menus++,
    );

    await tester.tap(find.bySemanticsLabel('PROJECTS'));
    await tester.tap(find.bySemanticsLabel('New note or upload'));
    await tester.tap(find.bySemanticsLabel('Start recording'));

    expect(selected, 1);
    expect(menus, 1);
    expect(recordings, 1);
  });

  testWidgets('interactive targets are at least 44 logical pixels square', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpBar(
      tester,
      onSelected: (_) {},
      onRecord: () {},
      onOpenCaptureMenu: () {},
    );

    for (final String label in <String>[
      'QUEUE',
      'PROJECTS',
      'MODELS',
      'LOGS',
      'CONFIG',
      'New note or upload',
      'Start recording',
    ]) {
      expect(
        tester.getSize(find.bySemanticsLabel(label)).height,
        greaterThanOrEqualTo(44),
        reason: '$label must meet the minimum touch-target height',
      );
      expect(
        tester.getSize(find.bySemanticsLabel(label)).width,
        greaterThanOrEqualTo(44),
        reason: '$label must meet the minimum touch-target width',
      );
    }

    expect(
      find.bySemanticsLabel('New note or upload').hitTestable(),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Start recording').hitTestable(),
      findsOneWidget,
    );
  });
}

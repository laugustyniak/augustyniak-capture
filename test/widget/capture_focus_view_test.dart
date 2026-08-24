import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_row.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// The queue's one way into a capture: tapping it.
///
/// Both forms are asserted here rather than in the card's and the row's own
/// suites, because the claim is that they agree — the desktop card body and the
/// compact row open the same view, and the phone has no second surface (the
/// accordion) that could drift from it.
void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_focus_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  /// Scoped to the dialog on purpose: the queue is still built underneath it,
  /// and the card there renders the same capture's text — raw, three lines of
  /// it. An unscoped finder would be satisfied by the card and would pass
  /// against a focus view that rendered nothing at all.
  Finder inFocusView(Finder matching) =>
      find.descendant(of: find.byType(Dialog), matching: matching);

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller, {
    Size surface = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
  }

  testWidgets('tapping the card body opens the focus view', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'body_tap',
          title: 'Kitchen rebuild',
          transcript: 'Ring the joiner about the worktop.',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.byType(Dialog), findsNothing);
    // The title, not a button: the point is that dead space on the card is
    // now the tap target.
    await tester.tap(find.text('Kitchen rebuild'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.bySemanticsLabel('Close focus view'), findsOneWidget);
    expect(find.byTooltip('Copy full text'), findsOneWidget);
  });

  testWidgets('a control on the card still wins the tap', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'button_tap',
          title: 'Kitchen rebuild',
          transcript: 'Ring the joiner about the worktop.',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byTooltip('Copy text'));
    await tester.pumpAndSettle();

    // The copy button consumed it; the body gesture underneath did not also
    // fire and open a dialog over the queue.
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'tapping a compact row opens the focus view rather than expanding',
    (WidgetTester tester) async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'row_tap',
            title: 'Kitchen rebuild',
            summary: 'Chase the worktop.',
            transcript: 'Ring the joiner about the worktop.',
          ),
        ],
      );
      await pumpQueue(tester, controller, surface: const Size(393, 852));

      expect(find.byType(RecordingRow), findsOneWidget);
      // Collapsed: the row is one line, so the summary is not on screen until
      // the capture is opened.
      expect(find.text('Chase the worktop.'), findsNothing);

      await tester.tap(find.text('Kitchen rebuild'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Chase the worktop.'), findsOneWidget);
      expect(find.text('Ring the joiner about the worktop.'), findsOneWidget);
    },
  );

  testWidgets('the focus view renders the capture as markdown', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'markdown',
          title: 'Standup',
          transcript:
              '## Plan\n\n'
              '- call the joiner\n'
              '- **order** the worktop\n',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Standup'));
    await tester.pumpAndSettle();

    // The markers are consumed rather than printed: a heading is a heading and
    // a bullet is a bullet.
    expect(inFocusView(find.text('Plan')), findsOneWidget);
    expect(inFocusView(find.textContaining('## Plan')), findsNothing);
    expect(inFocusView(find.text('call the joiner')), findsOneWidget);
    expect(inFocusView(find.textContaining('**order**')), findsNothing);
  });

  testWidgets('the focus view follows the capture while it is open', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'live',
          title: 'Standup',
          transcript: 'Ring the joiner.',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.text('Standup'));
    await tester.pumpAndSettle();
    expect(inFocusView(find.text('Ring the joiner.')), findsOneWidget);

    // A snapshot-based modal would still be showing the old text here.
    await controller.editTranscript('live', 'Ring the joiner about the sink.');
    await tester.pumpAndSettle();

    expect(
      inFocusView(find.text('Ring the joiner about the sink.')),
      findsOneWidget,
    );
  });

  testWidgets('the card keeps its explicit focus-view button', (
    WidgetTester tester,
  ) async {
    bool opened = false;
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: makeRecording(
            id: 'explicit',
            transcript: 'Line one.\nLine two.\nLine three.\nLine four.',
          ),
          isPlaying: false,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
          onOpenFocus: () => opened = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Focus view'));
    await tester.pump();

    expect(opened, isTrue);
  });

  testWidgets('a card with nowhere to open stays inert', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: makeRecording(
            id: 'inert',
            transcript: 'Line one.\nLine two.\nLine three.\nLine four.',
          ),
          isPlaying: false,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
        ),
      ),
    );
    await tester.pump();

    // A button that could only ever do nothing is worse than no button — the
    // same rule `canRoute` follows.
    expect(find.byTooltip('Focus view'), findsNothing);
  });

  testWidgets('the palette stays live inside the focus view', (
    WidgetTester tester,
  ) async {
    // `Console`'s colours are mutable globals, so anything painting them must
    // not be `const` — a const subtree keeps the old theme after a swap. This
    // asserts the view builds under both, which is the cheapest guard the
    // suite can carry for it.
    for (final ConsolePalette palette in <ConsolePalette>[
      ConsolePalette.dark,
      ConsolePalette.light,
    ]) {
      Console.activate(palette);
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'theme', title: 'Standup', transcript: 'Body.'),
        ],
      );
      await pumpQueue(tester, controller);
      await tester.tap(find.text('Standup'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('CLOSE'));
      await tester.pumpAndSettle();
    }
    Console.activate(ConsolePalette.dark);
  });

  testWidgets('the card excerpt shows the text without its markers', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'excerpt',
          title: 'Standup',
          transcript: '## Plan\n\n- call the **joiner**\n',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    // The card cannot render markdown — three lines at one size — but it can
    // stop printing the markup at the reader.
    expect(find.text('Plan\ncall the joiner'), findsOneWidget);
    expect(find.textContaining('## Plan'), findsNothing);
  });

  testWidgets('Enter opens the keyboard-selected row, but not while typing', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(id: 'typed', title: 'Standup', transcript: 'Body.'),
      ],
    );
    await pumpQueue(tester, controller);

    // Nothing is selected when the tab opens — a selection the user did not
    // ask for would make the first key press act on a guessed capture.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    // The row is still selected, so this is the same key that just opened it —
    // only the focus has moved into the search box, which is what has to
    // swallow it. A real key event, not `receiveAction`: the soft-keyboard
    // action never reaches the shortcut layer, so asserting on that would
    // pass against a binding that does fire on the hardware key.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'stand');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byType(Dialog), findsNothing);
  });
}

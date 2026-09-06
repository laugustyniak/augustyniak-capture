import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_editor.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'recording_editor_widget_test_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller),
        listenable: controller,
      ),
    );
    await tester.pump();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('clicking edit icon on card switches to RecordingEditor', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'Initial Title',
          transcript: 'Initial transcript text',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    expect(find.byType(RecordingCard), findsOneWidget);
    expect(find.byType(RecordingEditor), findsNothing);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    expect(find.byType(RecordingEditor), findsOneWidget);
    expect(find.text('EDITING'), findsOneWidget);
  });

  testWidgets('editing title shows revert button and reverts on tap', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'Original Title',
          transcript: 'Transcript text',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder titleField = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.byType(TextField),
    ).first;

    expect(find.bySemanticsLabel(RecordingEditor.revertTitleLabel), findsNothing);

    await tester.enterText(titleField, 'Modified Title But Unsaved');
    await tester.pump();

    expect(find.bySemanticsLabel(RecordingEditor.revertTitleLabel), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RecordingEditor.revertTitleLabel));
    await tester.pump();

    expect(find.bySemanticsLabel(RecordingEditor.revertTitleLabel), findsNothing);
    expect(controller.recordings.single.title, 'Original Title');
  });

  testWidgets('submitting title commits change and updates UI immediately', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'Old Title',
          transcript: 'Transcript text',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder titleField = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.byType(TextField),
    ).first;

    await tester.enterText(titleField, 'Brand New Title');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester);

    expect(controller.recordings.single.title, 'Brand New Title');

    // Finish editing
    final Finder doneButton = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.text('DONE'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(doneButton);
    await tester.pump();
    await tester.tap(doneButton);
    await settleIo(tester);

    expect(find.byType(RecordingEditor), findsNothing);
    expect(find.text('Brand New Title'), findsOneWidget);
  });

  testWidgets('editing transcript text shows UNSAVED and reverts on tap', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'Title',
          transcript: 'Saved transcript body',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder textField = find.widgetWithText(
      TextField,
      'Saved transcript body',
    );
    expect(textField, findsOneWidget);
    expect(find.bySemanticsLabel(RecordingEditor.revertTextLabel), findsNothing);

    await tester.enterText(textField, 'Temporary unsaved text');
    await tester.pump();

    final Finder revertButton = find.bySemanticsLabel(
      RecordingEditor.revertTextLabel,
    );
    expect(revertButton, findsOneWidget);

    tester
        .widget<InkResponse>(
          find.descendant(
            of: revertButton,
            matching: find.byType(InkResponse),
          ),
        )
        .onTap!();
    await tester.pump();

    expect(find.bySemanticsLabel(RecordingEditor.revertTextLabel), findsNothing);
    expect(controller.recordings.single.transcript, 'Saved transcript body');
  });

  testWidgets('DONE button commits pending transcript and exits edit mode', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'My Capture',
          transcript: 'Original transcript text',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder textField = find.widgetWithText(
      TextField,
      'Original transcript text',
    );
    await tester.enterText(textField, 'Committed edited transcript');
    await tester.pump();

    final Finder doneButton = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.text('DONE'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(doneButton);
    await tester.pump();
    await tester.tap(doneButton);
    await settleIo(tester);

    expect(find.byType(RecordingEditor), findsNothing);
    expect(controller.recordings.single.transcript, 'Committed edited transcript');
    expect(find.textContaining('Committed edited transcript'), findsOneWidget);
  });

  testWidgets('blank transcript edit restores original text on blur', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'My Capture',
          transcript: 'Cannot be emptied',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder textField = find.widgetWithText(
      TextField,
      'Cannot be emptied',
    );
    await tester.enterText(textField, '   ');
    await tester.pump();

    final Finder doneButton = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.text('DONE'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(doneButton);
    await tester.pump();
    await tester.tap(doneButton);
    await settleIo(tester);

    expect(controller.recordings.single.transcript, 'Cannot be emptied');
  });

  testWidgets('Escape key commits pending edits and exits edit mode', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'item-1',
          title: 'Before Escape',
          transcript: 'Transcript before escape',
        ),
      ],
    );
    await pumpQueue(tester, controller);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    final Finder titleField = find.descendant(
      of: find.byType(RecordingEditor),
      matching: find.byType(TextField),
    ).first;
    await tester.enterText(titleField, 'After Escape Title');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleIo(tester);

    expect(find.byType(RecordingEditor), findsNothing);
    expect(controller.recordings.single.title, 'After Escape Title');
  });
}

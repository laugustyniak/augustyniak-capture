import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// Two properties of the queue list that no other suite could see, because both
/// are about what the list does *not* do: it does not build a row nobody can
/// see, and it does not greet an unconfigured install with the durability
/// guarantee while every capture it takes is failing.
void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_empty_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller, {
    bool hasTranscriptionProfile = true,
    VoidCallback? onConfigureModels,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(
          controller: controller,
          hasTranscriptionProfile: hasTranscriptionProfile,
          onConfigureModels: onConfigureModels,
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
  }

  group('list scale', () {
    testWidgets('builds only the rows the viewport can show', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Far more than fits, and far more than a `children:` list could build
      // without paying for every one of them on every controller notification.
      const int total = 200;
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          for (int i = 0; i < total; i++)
            makeRecording(id: 'r$i', transcript: 'capture number $i'),
        ],
      );
      await pumpQueue(tester, controller);

      final int built = tester.widgetList(find.byType(RecordingCard)).length;
      expect(
        built,
        lessThan(total),
        reason:
            'ListView.builder must not instantiate every row; a `children:` '
            'list builds all $total.',
      );
      // The viewport plus `cacheExtent` is a couple of screens' worth, never a
      // fifth of the queue. Asserting an upper bound rather than an exact count
      // keeps the test from breaking when a card's height changes.
      expect(built, lessThan(total ~/ 4));
      // ...and it still rendered something, so a passing test cannot mean the
      // list quietly stopped drawing.
      expect(built, greaterThan(0));
    });
  });

  group('empty states', () {
    testWidgets('a first run with no profile is named and offers the way out', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = await buildRecordingsController(appDir);
      int taps = 0;
      await pumpQueue(
        tester,
        controller,
        hasTranscriptionProfile: false,
        onConfigureModels: () => taps++,
      );

      expect(find.text('No transcription model configured.'), findsOneWidget);
      expect(find.text('Nothing captured yet.'), findsNothing);

      await tester.tap(find.text('SET UP A MODEL'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('the button is omitted when there is nowhere to send the user', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = await buildRecordingsController(appDir);
      await pumpQueue(tester, controller, hasTranscriptionProfile: false);

      expect(find.text('No transcription model configured.'), findsOneWidget);
      expect(find.text('SET UP A MODEL'), findsNothing);
    });

    testWidgets('a configured first run keeps the original greeting', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = await buildRecordingsController(appDir);
      await pumpQueue(tester, controller);

      expect(find.text('Nothing captured yet.'), findsOneWidget);
      expect(find.text('No transcription model configured.'), findsNothing);
    });

    testWidgets('a filtered-empty queue never claims the setup is unfinished', (
      WidgetTester tester,
    ) async {
      // The setup prompt answers "you have not configured this yet". Once there
      // are captures the user has already met the failure and the filters are
      // the live question, so the prompt must step aside even with no profile.
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[makeRecording(id: 'a', isProcessedByUser: true)],
      );
      await pumpQueue(tester, controller, hasTranscriptionProfile: false);

      expect(find.text('No transcription model configured.'), findsNothing);
      expect(find.textContaining('Desk clear'), findsOneWidget);
    });

    testWidgets(
      'an unconfigured failed capture offers SET UP MODEL on the card',
      (WidgetTester tester) async {
        final RecordingsController controller = await buildRecordingsController(
          appDir,
          seed: <Recording>[
            makeRecording(
              id: 'unconfigured_1',
              status: RecordingStatus.failed,
              error: 'Transcription endpoint is not configured.',
            ),
          ],
        );
        int configureTaps = 0;
        await pumpQueue(
          tester,
          controller,
          hasTranscriptionProfile: false,
          onConfigureModels: () => configureTaps++,
        );

        expect(find.text('SET UP MODEL'), findsOneWidget);
        await tester.tap(find.text('SET UP MODEL'));
        await tester.pump();
        expect(configureTaps, 1);
      },
    );

    testWidgets(
      'an unconfigured failed capture in focus view offers SET UP A MODEL button',
      (WidgetTester tester) async {
        final RecordingsController controller = await buildRecordingsController(
          appDir,
          seed: <Recording>[
            makeRecording(
              id: 'unconfigured_focus',
              status: RecordingStatus.failed,
              error: 'Transcription endpoint is not configured.',
            ),
          ],
        );
        int configureTaps = 0;
        await tester.pumpWidget(
          hostTab(
            () => Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () => showCaptureFocusView(
                  context,
                  controller: controller,
                  recordingId: 'unconfigured_focus',
                  onConfigureModels: () => configureTaps++,
                ),
                child: const Text('OPEN'),
              ),
            ),
            listenable: controller,
          ),
        );
        await tester.pump();

        // Open the dialog
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();

        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('SET UP A MODEL'), findsOneWidget);

        await tester.tap(find.text('SET UP A MODEL'));
        await tester.pumpAndSettle();

        expect(find.byType(Dialog), findsNothing);
        expect(configureTaps, 1);
      },
    );
  });
}

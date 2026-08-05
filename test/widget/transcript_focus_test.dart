import 'package:flutter_test/flutter_test.dart';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import '../support/harness.dart';

void main() {
  testWidgets('short transcript renders copy button but no expand/focus icons', (
    WidgetTester tester,
  ) async {
    final Recording recording = makeRecording(
      id: 'short_item',
      status: RecordingStatus.completed,
      transcript: 'Short transcript note',
    );

    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording,
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

    expect(find.text('Short transcript note'), findsOneWidget);
    expect(find.byTooltip('Copy text'), findsOneWidget);
    expect(find.byTooltip('Expand text'), findsNothing);
    expect(find.byTooltip('Focus view'), findsNothing);
  });

  testWidgets('long transcript renders expand and focus icons and toggles inline expansion', (
    WidgetTester tester,
  ) async {
    final String longText =
        'Line 1 of long transcription.\n'
        'Line 2 of long transcription.\n'
        'Line 3 of long transcription.\n'
        'Line 4 of long transcription.\n'
        'Line 5 of long transcription.';

    final Recording recording = makeRecording(
      id: 'long_item',
      status: RecordingStatus.completed,
      transcript: longText,
    );

    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording,
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

    expect(find.byTooltip('Expand text'), findsOneWidget);
    expect(find.byTooltip('Focus view'), findsOneWidget);

    // Tap expand button
    await tester.tap(find.byTooltip('Expand text'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Collapse text'), findsOneWidget);

    // Tap collapse button back
    await tester.tap(find.byTooltip('Collapse text'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Expand text'), findsOneWidget);
  });

  testWidgets('tapping focus view opens focus modal dialog with word stats', (
    WidgetTester tester,
  ) async {
    bool edited = false;
    final String longText =
        'First paragraph of long audio recording.\n\n'
        'Second paragraph containing detailed insights and notes.';

    final Recording recording = makeRecording(
      id: 'focus_item',
      status: RecordingStatus.completed,
      transcript: longText,
    );

    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording,
          isPlaying: false,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () => edited = true,
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
        ),
      ),
    );
    await tester.pump();

    // Open focus view modal
    await tester.tap(find.byTooltip('Focus view'));
    await tester.pumpAndSettle();

    // Verify modal dialog contents
    expect(find.textContaining('words ·'), findsOneWidget);
    expect(find.textContaining('characters'), findsOneWidget);
    expect(find.byTooltip('Copy full text'), findsOneWidget);
    expect(find.text('CLOSE'), findsOneWidget);

    // Test EDIT action in focus modal
    await tester.tap(find.text('EDIT'));
    await tester.pumpAndSettle();

    expect(edited, isTrue);
  });
}

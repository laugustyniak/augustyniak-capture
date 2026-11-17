import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/suggested_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A pill carrying free-form user text — a project name — must shrink to the
/// card instead of overflowing it. In the narrow layout the pills `Wrap` gives
/// the project pill its own run, but a pill wider than the run cannot wrap, so
/// before the fix a 57-character name overflowed a 420 px card by ~71 px.
void main() {
  // 57 characters, the length the overflow was first seen at.
  const String longName =
      'Quarterly infrastructure migration and observability work';

  final Recording recording = makeRecording(
    id: 'long-project',
    title: 'Call about the migration',
    transcript: 'notes',
    projectId: 'p1',
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    required double width,
    required String projectName,
    bool withSuggestion = false,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording,
          projectName: projectName,
          isPlaying: false,
          isEnriching: false,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
          suggestedRoute: withSuggestion
              ? const SuggestedRouteAction(
                  kind: SuggestedRouteKind.file,
                  reason: 'Belongs to the project',
                )
              : null,
          onConfirmSuggestedRoute: withSuggestion ? () {} : null,
          onDismissSuggestedRoute: withSuggestion ? () {} : null,
        ),
      ),
    );
    await tester.pump();
  }

  Finder projectPill(String name) => find.byWidgetPredicate(
    (Widget widget) => widget is StatusPill && widget.label == name,
  );

  test('the fixture name is the 57 characters the issue measured', () {
    expect(longName.length, 57);
  });

  for (final bool withSuggestion in <bool>[false, true]) {
    final String variant = withSuggestion
        ? 'with the suggestion chip'
        : 'without the suggestion chip';

    testWidgets('a 57-character project name fits a 420 px card $variant', (
      WidgetTester tester,
    ) async {
      await pumpCard(
        tester,
        width: 420,
        projectName: longName,
        withSuggestion: withSuggestion,
      );

      expect(tester.takeException(), isNull);
      expect(projectPill(longName), findsOneWidget);
      // Whatever the pill had to cut, the whole name is still one hover away.
      expect(find.byTooltip(longName), findsOneWidget);
      final double pillWidth = tester.getSize(projectPill(longName)).width;
      expect(pillWidth, lessThan(420));
    });
  }

  testWidgets('a short project name keeps its full width at 900 px', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, width: 900, projectName: 'Acme');

    expect(tester.takeException(), isNull);
    // Rendered whole: no ellipsis has eaten into a name that fits.
    final Text label = tester.widget<Text>(
      find.descendant(of: projectPill('Acme'), matching: find.byType(Text)),
    );
    expect(label.data, 'Acme');
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: projectPill('Acme'), matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  });
}

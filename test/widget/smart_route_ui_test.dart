import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/smart_route.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/settings/presentation/smart_route_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  final Finder button = find.byWidgetPredicate(
    (Widget w) =>
        w is ConsoleIconButton &&
        w.semanticLabel == RecordingCard.smartRouteLabel,
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    required bool can,
    VoidCallback? onSmartRoute,
    Recording? recording,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording ?? makeRecording(id: 'r', transcript: 'hello'),
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
          canSmartRoute: can,
          onSmartRoute: onSmartRoute ?? () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the button is hidden, not disabled, when nothing can deliver', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, can: false);
    expect(button, findsNothing);
  });

  testWidgets('the button is drawn and fires when something can deliver', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    await pumpCard(tester, can: true, onSmartRoute: () => taps++);
    expect(button, findsOneWidget);
    await tester.tap(button);
    expect(taps, 1);
  });

  testWidgets('a reviewed capture does not draw it', (
    WidgetTester tester,
  ) async {
    await pumpCard(
      tester,
      can: true,
      recording: makeRecording(
        id: 'r',
        transcript: 'hello',
        isProcessedByUser: true,
      ),
    );
    expect(button, findsNothing);
  });

  testWidgets('the Config section saves the command and the confirm mode', (
    WidgetTester tester,
  ) async {
    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    await tester.pumpWidget(
      hostTab(() => SmartRouteSection(controller: settings)),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey<String>('todoist-agent-command')),
      'claude --mcp-config ~/t.json',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(settings.todoistAgentCommand, 'claude --mcp-config ~/t.json');
    expect(find.textContaining('TODOIST INTENT ON'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('smart-route-confirm')));
    await tester.pump();
    expect(settings.smartRouteConfirm, SmartRouteConfirm.confirmEffects);
  });

  testWidgets('a refused command is explained in the field\'s own section', (
    WidgetTester tester,
  ) async {
    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    await tester.pumpWidget(
      hostTab(() => SmartRouteSection(controller: settings)),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('todoist-agent-command')),
      'claude --yolo',
    );
    await tester.pump();
    expect(find.textContaining('not allowed here'), findsOneWidget);
    expect(find.textContaining('TODOIST INTENT ON'), findsNothing);
  });
}

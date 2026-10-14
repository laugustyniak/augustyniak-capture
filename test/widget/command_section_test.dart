import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/presentation/command_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The Command section is where a public `http://` address is refused (#299):
/// the field stays UNSAVED with the reason under it, the stored pair is
/// untouched, and a value that reached disk before the guard existed is
/// labelled rather than silently disabled.
///
/// No `pumpAndSettle` here: `enterText` focuses a `TextField`, and a focused
/// field's cursor blinks forever (`docs/architecture/testing-widgets.md`).
void main() {
  Future<SettingsController> controllerWith({AppSettings? stored}) async {
    final SettingsController controller = buildSettingsController(
      stored: stored,
    );
    await controller.initialize();
    return controller;
  }

  Future<void> pumpSection(
    WidgetTester tester,
    SettingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => SingleChildScrollView(
          child: CommandSection(controller: controller),
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
  }

  Finder addressField() => find.byType(TextField).first;

  Future<void> submitAddress(WidgetTester tester, String value) async {
    await tester.enterText(addressField(), value);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    // The save is one awaited fake-repository call plus one setState.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a public http address is refused and stays unsaved', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller);

    await submitAddress(tester, 'http://203.0.113.10');

    expect(find.text('UNSAVED'), findsOneWidget);
    expect(
      find.textContaining('Not saved: http://203.0.113.10'),
      findsOneWidget,
    );
    expect(controller.settings.commandBaseUrl, isNull);
    expect(find.text('OFF'), findsOneWidget);
  });

  testWidgets('a private-network http address saves', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWith();
    await pumpSection(tester, controller);

    await submitAddress(tester, 'http://192.168.1.10');

    expect(find.text('UNSAVED'), findsNothing);
    expect(find.textContaining('Not saved'), findsNothing);
    expect(controller.settings.commandBaseUrl, 'http://192.168.1.10');
    expect(find.text('CONFIGURED'), findsOneWidget);
  });

  testWidgets('the refusal clears on the next keystroke', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWith(
      stored: AppSettings.empty.copyWith(
        commandBaseUrl: 'https://fleet.example.com',
      ),
    );
    await pumpSection(tester, controller);
    await submitAddress(tester, 'http://203.0.113.10');
    expect(find.textContaining('Not saved'), findsOneWidget);

    // Typing the stored value back makes the field clean, so no save runs:
    // the message has to go on the keystroke, not on a save.
    await tester.enterText(addressField(), 'https://fleet.example.com');
    await tester.pump();

    expect(find.textContaining('Not saved'), findsNothing);
    expect(find.text('UNSAVED'), findsNothing);
  });

  testWidgets('a stored public http address is labelled and disabled', (
    WidgetTester tester,
  ) async {
    // Written before the save-time guard existed; the client is already
    // disabled, and the section says why instead of just reading OFF.
    final SettingsController controller = await controllerWith(
      stored: AppSettings.empty.copyWith(
        commandBaseUrl: 'http://203.0.113.10',
        commandToken: 'fleet-token',
      ),
    );
    await pumpSection(tester, controller);

    expect(
      find.byWidgetPredicate(
        (Widget w) => w is StatusPill && w.label == 'NO TLS',
      ),
      findsOneWidget,
    );
    expect(find.text('OFF'), findsOneWidget);
    expect(controller.commandClient.isConfigured, isFalse);
  });

  testWidgets('an https address shows no pill', (WidgetTester tester) async {
    final SettingsController controller = await controllerWith(
      stored: AppSettings.empty.copyWith(
        commandBaseUrl: 'https://fleet.example.com',
      ),
    );
    await pumpSection(tester, controller);

    expect(
      find.byWidgetPredicate(
        (Widget w) => w is StatusPill && w.label == 'NO TLS',
      ),
      findsNothing,
    );
    expect(find.text('CONFIGURED'), findsOneWidget);
  });
}

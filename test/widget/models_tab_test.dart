import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes_phase1/features/settings/presentation/models_tab.dart';
import 'package:voice_notes_phase1/features/settings/presentation/settings_controller.dart';

import '../support/harness.dart';

/// Guards the profile list before the destructive-confirm dialog and the
/// icon-tile pattern are extracted into `ui_kit.dart`.
void main() {
  Future<void> pumpModels(
    WidgetTester tester,
    SettingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(() => ModelsTab(controller: controller), listenable: controller),
    );
    await tester.pump();
  }

  Future<SettingsController> controllerWithProfiles(int count) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    for (int i = 0; i < count; i++) {
      await controller.addProfile(
        name: 'Profil $i',
        endpoint: 'https://host$i.example/v1/audio/transcriptions',
      );
    }
    return controller;
  }

  testWidgets('with no profiles it explains transcription is off', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpModels(tester, controller);

    expect(find.text('No transcription profiles.'), findsOneWidget);
    expect(find.text('Transcription disabled'), findsOneWidget);
    expect(find.text('NOT CONFIGURED'), findsOneWidget);
  });

  testWidgets('profiles are listed with their host and count', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(2);
    await pumpModels(tester, controller);

    expect(find.text('Profil 0'), findsOneWidget);
    expect(find.text('Profil 1'), findsWidgets);
    expect(find.text('2 ITEMS'), findsOneWidget);
  });

  testWidgets('the newest profile is active and shows the ACTIVE pill', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(2);
    await pumpModels(tester, controller);

    expect(controller.activeProfile?.name, 'Profil 1');
    expect(find.text('ACTIVE PROVIDER'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
  });

  testWidgets('tapping an inactive profile makes it active', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(2);
    await pumpModels(tester, controller);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();

    expect(controller.activeProfile?.name, 'Profil 0');
  });

  testWidgets('cancelling the delete dialog keeps the profile', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(1);
    await pumpModels(tester, controller);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete profile?'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(controller.profiles, hasLength(1));
  });

  testWidgets('confirming the delete removes it and disables transcription', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(1);
    await pumpModels(tester, controller);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DELETE'));
    await tester.pumpAndSettle();

    expect(controller.profiles, isEmpty);
    expect(controller.activeProfile, isNull);
    expect(find.text('No transcription profiles.'), findsOneWidget);
  });

  testWidgets('the plaintext-token warning is always visible', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpModels(tester, controller);

    expect(find.textContaining('plaintext'), findsOneWidget);
  });
}

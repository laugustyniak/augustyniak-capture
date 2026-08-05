import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/models_tab.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';

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

  /// The tab is one long ListView, so anything past the first screen has to be
  /// scrolled into existence before it can be found at all.
  Future<void> scrollTo(WidgetTester tester, Finder target) =>
      tester.scrollUntilVisible(
        target,
        200,
        scrollable: find.byType(Scrollable).first,
      );

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

    // The enrichment section sits below the fold on a fresh install, and a
    // ListView only builds what is on screen.
    await scrollTo(tester, find.text('No enrichment profiles.'));
    // Its own active-profile card, independently unconfigured — the transcription
    // one has scrolled out of the build by now.
    expect(find.text('Enrichment disabled'), findsOneWidget);
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
    // Below the fold since the tab grew a second section.
    await scrollTo(tester, find.textContaining('plaintext'));

    expect(find.textContaining('plaintext'), findsOneWidget);
  });

  testWidgets('each stage gets its own section header', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpModels(tester, controller);

    expect(find.text('TRANSCRIPTION PROFILES'), findsOneWidget);
    await scrollTo(tester, find.text('ENRICHMENT PROFILES'));
    expect(find.text('ENRICHMENT PROFILES'), findsOneWidget);
  });

  testWidgets('an enrichment profile is listed apart and activated apart', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = await controllerWithProfiles(1);
    final ProviderProfile gpt = await controller.addProfile(
      name: 'GPT',
      endpoint: 'https://api.openai.com/v1/chat/completions',
      kind: ProfileKind.enrichment,
      model: 'gpt-4o-mini',
    );
    final ProviderProfile groq = await controller.addProfile(
      name: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      kind: ProfileKind.enrichment,
    );
    await pumpModels(tester, controller);

    // Each section counts only its own kind.
    expect(find.text('1 ITEMS'), findsOneWidget);
    expect(controller.settings.activeEnrichmentProfileId, groq.id);

    final String transcriptionActive = controller.settings.activeProfileId!;
    await scrollTo(tester, find.text('GPT'));
    // scrollUntilVisible stops the moment the row touches the bottom edge, where
    // a tap lands outside the viewport; nudge it fully into view first.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
    await tester.pump();
    expect(find.text('2 ITEMS'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('GPT'),
          matching: find.byType(ConsoleCard),
        ),
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
    );
    await tester.pump();

    expect(controller.settings.activeEnrichmentProfileId, gpt.id);
    // Activating an enrichment profile must never repoint transcription.
    expect(controller.settings.activeProfileId, transcriptionActive);
  });

  // The enrichment profile is also the only OCR engine. So the three
  // vision-capable presets have
  // to be reachable in the sheet, not merely present in `ProviderPreset.all`:
  // the chips live in a horizontally scrolling ListView that builds only what is
  // on screen, so a fourth preset added ahead of them would push one out of
  // reach with every unit test still green.
  testWidgets('the vision presets are offered and fill the enrichment form', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpModels(tester, controller);

    await scrollTo(tester, find.text('ADD ENRICHMENT PROFILE'));
    await tester.tap(find.text('ADD ENRICHMENT PROFILE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('NEW ENRICHMENT PROFILE'), findsOneWidget);
    for (final String name in <String>[
      'OpenAI',
      'Anthropic',
      'Google Gemini',
    ]) {
      expect(
        find.widgetWithText(ActionChip, name),
        findsOneWidget,
        reason: name,
      );
    }

    // Applying the preset has to reach the fields, or the chip is decoration:
    // the endpoint it writes is what `toOcrService` parses, and a schemeless one
    // degrades to the disabled service without a word.
    await tester.tap(find.widgetWithText(ActionChip, 'Google Gemini'));
    await tester.pump();

    expect(
      find.widgetWithText(
        TextFormField,
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      ),
      findsOneWidget,
    );
    // Scoped to the field rather than `find.text`: the same string is also on a
    // suggestion chip once the preset matches, so a bare text finder would read
    // "too many" — and, worse, would pass on the chip alone if the field never
    // got filled.
    expect(
      find.widgetWithText(TextFormField, 'gemini-3.6-flash'),
      findsOneWidget,
    );
    // The suggestion row only renders once the endpoint host matches a preset,
    // so its presence is what proves the round-trip rather than a lucky string.
    expect(find.widgetWithText(ActionChip, 'gemini-3.1-pro'), findsOneWidget);
    expect(find.text('Google AI Studio API key (AIza…)'), findsOneWidget);
  });
}

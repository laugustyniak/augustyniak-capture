import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/presentation/models_tab.dart';
import 'package:augustyniak_capture/features/transcription/data/whisper_model_store.dart';
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
      hostTab(
        () => ModelsTab(controller: controller, modelStore: _SilentStore()),
        listenable: controller,
      ),
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
    // a tap lands outside the viewport. `ensureVisible` brings it fully in
    // without a hand-tuned offset — the drag that used to do it was measured
    // against a two-section tab and overshot once a third arrived.
    await tester.ensureVisible(find.text('GPT'));
    await tester.pump();
    // The enrichment header's own count, asserted where it is on screen rather
    // than from a fixed scroll offset — the tab has gained a third section
    // below and the old assumption about what stayed in view with it.
    // ignore: avoid_print
    print('DEBUG items: ${find.textContaining('ITEMS').evaluate().map((e) => (e.widget as Text).data).toList()}');
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

  testWidgets('an unopenable token is reported as a failure, not as plaintext', (
    WidgetTester tester,
  ) async {
    // The screen that was on display while every capture came back 401: the
    // tokens were encrypted and unreadable, and the only note about them said
    // they were sitting on disk in the clear. Opposite claim, same amber line.
    final SettingsController controller = buildSettingsController(
      stored: const AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'p1',
            name: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            bearerToken: 'enc:v1:unreadable-blob',
          ),
        ],
        activeProfileId: 'p1',
      ),
    );
    await controller.initialize();
    await pumpModels(tester, controller);

    await scrollTo(tester, find.textContaining('cannot be decrypted'));
    expect(find.textContaining('cannot be decrypted'), findsOneWidget);
    expect(find.textContaining('plaintext'), findsNothing);
  });

  testWidgets('the storage note names neither settings.json nor the keyring', (
    WidgetTester tester,
  ) async {
    // Both claims went stale under the same pair of commits: settings moved to
    // SQLite, and the master key moved to a file beside it because the keyring
    // keys access to a code signature an ad-hoc build changes on every build.
    // A note about where a reader's secrets live is the one place that must not
    // be approximately right.
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpModels(tester, controller);

    await scrollTo(tester, find.textContaining('plaintext'));
    expect(find.textContaining('settings.json'), findsNothing);
    expect(find.textContaining('keyring'), findsNothing);
  });

  testWidgets('a sealed token is not advertised as set', (
    WidgetTester tester,
  ) async {
    // Found by looking at the built app rather than by a failing assertion: the
    // profile card kept a green TOKEN SET beside the red banner, because the
    // pill tested `bearerToken != null` and a blob is not null. The two claims
    // on one screen contradict each other, and the green one is the lie —
    // `usableBearerToken` is what a request actually gets, and it is null here.
    final SettingsController controller = buildSettingsController(
      stored: const AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'p1',
            name: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            bearerToken: 'enc:v1:unreadable-blob',
          ),
        ],
        activeProfileId: 'p1',
      ),
    );
    await controller.initialize();
    await pumpModels(tester, controller);

    expect(find.text('TOKEN SET'), findsNothing);
    expect(find.text('TOKEN LOCKED'), findsOneWidget);
  });

  testWidgets('a usable token still says TOKEN SET', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController(
      stored: const AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'p1',
            name: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            bearerToken: 'sk-secret',
          ),
        ],
        activeProfileId: 'p1',
      ),
    );
    await controller.initialize();
    await pumpModels(tester, controller);

    expect(find.text('TOKEN SET'), findsOneWidget);
    expect(find.text('TOKEN LOCKED'), findsNothing);
  });

  testWidgets('a plaintext install still gets the plaintext note', (
    WidgetTester tester,
  ) async {
    // The guard on the test above: it must fail because the *state* is
    // different, not because the copy moved.
    final SettingsController controller = buildSettingsController(
      stored: const AppSettings(
        profiles: <ProviderProfile>[
          ProviderProfile(
            id: 'p1',
            name: 'OpenAI',
            endpoint: 'https://api.openai.com/v1/audio/transcriptions',
            bearerToken: 'sk-secret',
          ),
        ],
        activeProfileId: 'p1',
      ),
    );
    await controller.initialize();
    await pumpModels(tester, controller);

    await scrollTo(tester, find.textContaining('plaintext'));
    expect(find.textContaining('plaintext'), findsOneWidget);
    expect(find.textContaining('cannot be decrypted'), findsNothing);
  });

  /// The endpoint is free text behind a `hasScheme` guard, so `http://` is
  /// accepted as readily as `https://` — and then the token, the audio and the
  /// transcript all go out in the clear with nothing on screen saying so.
  testWidgets('a plain-http endpoint says so on the profile', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.addProfile(
      name: 'Leaky',
      endpoint: 'http://api.example.com/v1/audio/transcriptions',
    );
    await pumpModels(tester, controller);

    expect(find.text('NO TLS'), findsWidgets);
  });

  testWidgets('a local model server is not accused of anything', (
    WidgetTester tester,
  ) async {
    // `http://localhost:11434` is a preset this app ships. A warning on the
    // documented setup is a warning nobody reads on the real one.
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.addProfile(
      name: 'Ollama',
      endpoint: 'http://localhost:11434/v1/chat/completions',
    );
    await pumpModels(tester, controller);

    expect(find.text('NO TLS'), findsNothing);
  });
}

/// Nothing installed, and no filesystem touched.
///
/// The on-device section scans from `initState`, so without this every test in
/// this file would reach `path_provider` through the real store — the platform
/// channel the widget suite is written to avoid.
class _SilentStore extends WhisperModelStore {
  _SilentStore();

  @override
  Future<List<InstalledModel>> installed() async => const <InstalledModel>[];
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/settings/domain/app_theme_mode.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/settings/presentation/config_tab.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';

import '../support/harness.dart';

/// Guards the Config form before its `ChoiceChip` styling and `InputDecoration`
/// move into a shared theme — the latter is a known visual change, so the
/// behaviour needs pinning first.
void main() {
  /// The tab is a long form and the default 800x600 surface fits about a third
  /// of it, so half these tests used to reach their target by dragging a fixed
  /// distance. That is positional, and it broke the moment a section was added
  /// above: the drag either stopped short or landed on the enrichment field's
  /// own scrollable and was eaten by it. A surface tall enough to render the
  /// whole form removes the class of failure rather than re-tuning the numbers.
  Future<void> pumpConfig(
    WidgetTester tester,
    SettingsController controller, {
    List<Project> projects = const <Project>[],
  }) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(
        () => ConfigTab(
          controller: controller,
          storagePath: '/tmp/recordings',
          recordingsCount: 3,
          logCount: 7,
          onOpenModels: () {},
          projects: projects,
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the current capture parameters', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    expect(find.text('AUDIO CAPTURE'), findsOneWidget);
    expect(find.text('AAC-LC · .m4a (fixed)'), findsOneWidget);
    // The defaults name themselves — the Config tab marks the values the
    // pipeline was tuned for rather than leaving four equal-looking options.
    expect(find.text('16 kHz (Recommended)'), findsOneWidget);
    expect(find.text('64 kbps (Recommended)'), findsOneWidget);
    expect(find.text('Mono'), findsOneWidget);
  });

  testWidgets('the theme picker starts on SYSTEM and persists a choice', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(controller.themeMode, AppThemeMode.system);

    await tester.tap(find.text('LIGHT'));
    await tester.pumpAndSettle();

    expect(controller.themeMode, AppThemeMode.light);
    // Persisted like every other setting: the whole `settings.json` is
    // rewritten, so the choice survives a restart rather than the session.
    expect(controller.settings.themeMode, AppThemeMode.light);
  });

  testWidgets('picking a sample rate persists it through the controller', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    await tester.tap(find.text('44 kHz'));
    await tester.pumpAndSettle();

    expect(controller.audio.sampleRate, 44100);
  });

  testWidgets('switching to stereo updates the channel count', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    await tester.tap(find.text('Stereo'));
    await tester.pumpAndSettle();

    expect(controller.audio.numChannels, 2);
  });

  testWidgets('reset is disabled at defaults and enabled after a change', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    TextButton resetButton() => tester.widget<TextButton>(
      find.ancestor(
        of: find.text('RESTORE DEFAULTS'),
        matching: find.byType(TextButton),
      ),
    );

    expect(resetButton().onPressed, isNull);

    await tester.tap(find.text('32 kbps'));
    await tester.pumpAndSettle();
    expect(resetButton().onPressed, isNotNull);

    await tester.tap(find.text('RESTORE DEFAULTS'));
    await tester.pumpAndSettle();
    expect(controller.audio, AudioConfig.defaults);
  });

  testWidgets('with no active profile the transcription card warns', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    // Below the fold since the capture card grew its guidance text, and a
    // ListView does not build children it has not scrolled to.
    await tester.scrollUntilVisible(
      find.text('None — transcription off'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('None — transcription off'), findsOneWidget);
    expect(find.text('none'), findsOneWidget); // token
  });

  testWidgets('an active profile is summarised without leaking the token', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.addProfile(
      name: 'OpenAI',
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
      bearerToken: 'sk-super-secret',
    );
    await pumpConfig(tester, controller);
    await tester.scrollUntilVisible(
      find.text('OpenAI'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('whisper-1'), findsOneWidget);
    // The token value itself must never be rendered.
    expect(find.textContaining('sk-super-secret'), findsNothing);
    expect(find.textContaining('•••• set'), findsOneWidget);
  });

  testWidgets('storage section reports the paths and counts it was given', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    // The storage card sits below the fold; a ListView does not build children
    // it has not scrolled to.
    await tester.scrollUntilVisible(
      find.text('/tmp/recordings'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('/tmp/recordings'), findsOneWidget);
    expect(find.textContaining('3 .m4a files'), findsOneWidget);
    expect(find.textContaining('7 events'), findsOneWidget);
  });

  testWidgets('with no projects the section touches no disk and says so', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    await tester.scrollUntilVisible(
      find.text('ENRICHMENT CONTEXT'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    // No probe runs, so this settles — which is the whole point of defaulting
    // the project list to empty.
    await tester.pumpAndSettle();
    expect(
      find.text('No projects yet — captures carry the profile above only.'),
      findsOneWidget,
    );
    expect(find.text('RESCAN'), findsNothing);
  });

  testWidgets('the shortcuts section is hidden unless the shell enables it', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    // Desktop-only; the shell does the platform check, not the tab.
    expect(find.text('GLOBAL SHORTCUTS'), findsNothing);
  });

  testWidgets('font scale options and steppers update textScale', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    expect(find.text('FONT SCALE / ZOOM'), findsOneWidget);
    expect(find.text('100% (Default)'), findsOneWidget);
    expect(find.text('RESET (100%)'), findsNothing);

    // Tap 125%
    await tester.tap(find.text('125%'));
    await tester.pumpAndSettle();

    expect(controller.textScale, 1.25);
    expect(find.text('RESET (100%)'), findsOneWidget);

    // Reset back to 100%
    await tester.tap(find.text('RESET (100%)'));
    await tester.pumpAndSettle();

    expect(controller.textScale, 1.0);
    expect(find.text('RESET (100%)'), findsNothing);

    // Tap Zoom In stepper button
    await tester.tap(find.bySemanticsLabel('Zoom In (Ctrl +)'));
    await tester.pumpAndSettle();

    expect(controller.textScale, 1.1);

    // Tap Zoom Out stepper button
    await tester.tap(find.bySemanticsLabel('Zoom Out (Ctrl -)'));
    await tester.pumpAndSettle();

    expect(controller.textScale, 1.0);
  });
}

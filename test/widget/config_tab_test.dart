import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/domain/audio_config.dart';
import 'package:audivoa_core/features/settings/presentation/config_tab.dart';
import 'package:audivoa_core/features/settings/presentation/settings_controller.dart';

import '../support/harness.dart';

/// Guards the Config form before its `ChoiceChip` styling and `InputDecoration`
/// move into a shared theme — the latter is a known visual change, so the
/// behaviour needs pinning first.
void main() {
  Future<void> pumpConfig(
    WidgetTester tester,
    SettingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(
        () => ConfigTab(
          controller: controller,
          storagePath: '/tmp/recordings',
          recordingsCount: 3,
          logCount: 7,
          onOpenModels: () {},
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
    expect(find.text('16 kHz'), findsOneWidget);
    expect(find.text('64 kbps'), findsOneWidget);
    expect(find.text('Mono'), findsOneWidget);
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

  testWidgets('the shortcuts section is hidden unless the shell enables it', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    // Desktop-only; the shell does the platform check, not the tab.
    expect(find.text('GLOBAL SHORTCUTS'), findsNothing);
  });
}

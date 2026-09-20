import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/auth/presentation/auth_controller.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/app_theme_mode.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/settings/presentation/config_tab.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';

import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

/// Same shape as `test/widget/account_section_test.dart`'s fake — duplicated
/// rather than imported because it is library-private there.
class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({this.currentIdentity});

  @override
  AuthIdentity? currentIdentity;

  final StreamController<AuthIdentity?> changes =
      StreamController<AuthIdentity?>.broadcast();

  @override
  Stream<AuthIdentity?> get identityChanges => changes.stream;

  @override
  Future<bool> signInWithGoogle() async => true;

  @override
  Future<void> signOut() async {}
}

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
    bool showShortcuts = false,
    RecordingsController? recordingsController,
    ConfigCategory initialCategory = ConfigCategory.general,
    AuthController? authController,
  }) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(
        () => ConfigTab(
          controller: controller,
          authController: authController,
          recordingsController: recordingsController,
          storagePath: '/tmp/recordings',
          recordingsCount: 3,
          logCount: 7,
          onOpenModels: () {},
          projects: projects,
          showShortcuts: showShortcuts,
          initialCategory: initialCategory,
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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

    await tester.tap(find.text('44 kHz'));
    await tester.pumpAndSettle();

    expect(controller.audio.sampleRate, 44100);
  });

  testWidgets('switching to stereo updates the channel count', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

    await tester.tap(find.text('Stereo'));
    await tester.pumpAndSettle();

    expect(controller.audio.numChannels, 2);
  });

  testWidgets('reset is disabled at defaults and enabled after a change', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);
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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.data);

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
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.capture);

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

  testWidgets('desktop displays synchronized note count in note vault section', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.setVaultPath('/Users/you/Obsidian/Vault');

    // On mobile (showShortcuts: false)
    await pumpConfig(
      tester,
      controller,
      showShortcuts: false,
      initialCategory: ConfigCategory.capture,
    );
    await tester.scrollUntilVisible(
      find.text('NOTE VAULT'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('SYNCHRONIZED'), findsNothing);

    // On desktop (showShortcuts: true)
    await pumpConfig(
      tester,
      controller,
      showShortcuts: true,
      initialCategory: ConfigCategory.capture,
    );
    await tester.scrollUntilVisible(
      find.text('NOTE VAULT'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('SYNCHRONIZED'), findsOneWidget);
  });

  testWidgets('category tabs switch between sections', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    // Starts on GENERAL
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('AUDIO CAPTURE'), findsNothing);
    expect(find.text('LEGACY SYNC'), findsNothing);
    expect(find.text('STORAGE'), findsNothing);

    // Switch to CAPTURE & AI
    await tester.tap(find.text('CAPTURE & AI'));
    await tester.pumpAndSettle();
    expect(find.text('AUDIO CAPTURE'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsNothing);

    // Switch to SYNC & CLOUD
    await tester.tap(find.text('SYNC & CLOUD'));
    await tester.pumpAndSettle();
    expect(find.text('LEGACY SYNC'), findsOneWidget);
    expect(find.text('AUDIO CAPTURE'), findsNothing);

    // Switch to DATA & COSTS
    await tester.tap(find.text('DATA & COSTS'));
    await tester.pumpAndSettle();
    expect(find.text('ARCHIVE'), findsOneWidget);
    expect(find.text('LEGACY SYNC'), findsNothing);
  });

  testWidgets('one sync action covers configured Turso and R2', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.setTursoConfig(
      url: 'libsql://capture.turso.io',
      token: 'turso-token',
      enabled: true,
    );
    await controller.setR2Config(
      endpoint: 'https://account.r2.cloudflarestorage.com',
      bucket: 'captures',
      accessKeyId: 'access-key',
      secretAccessKey: 'secret-key',
      enabled: true,
    );

    await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

    expect(find.text('SYNC NOW'), findsOneWidget);
    expect(find.text('CONFIGURED · Ready'), findsNWidgets(2));
    expect(find.textContaining('101/101'), findsNothing);
    expect(find.textContaining('aws-us-east-1'), findsNothing);
  });

  testWidgets('the same action labels an R2-only sync accurately', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await controller.setR2Config(
      endpoint: 'https://account.r2.cloudflarestorage.com',
      bucket: 'captures',
      accessKeyId: 'access-key',
      secretAccessKey: 'secret-key',
      enabled: true,
    );

    await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

    expect(find.text('SYNC MEDIA'), findsOneWidget);
    expect(find.text('SYNC NOW (TURSO)'), findsNothing);
  });

  testWidgets('a sealed sync secret is reported, not shown as unconfigured', (
    WidgetTester tester,
  ) async {
    // The failure this pair exists for: every field is populated and correct,
    // the secret simply cannot be decrypted, and the tab used to render that
    // identically to a fresh install — one word, DISABLED, for two facts whose
    // recovery steps differ.
    final SettingsController controller = buildSettingsController(
      stored: const AppSettings(
        tursoDbUrl: 'libsql://capture.turso.io',
        tursoAuthToken: 'enc:v1:unreadable-blob',
        tursoSyncEnabled: true,
      ),
    );
    await controller.initialize();
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

    expect(controller.syncSecretsUnreadable, isTrue);
    // Turso is populated-but-sealed, R2 is genuinely absent. The two rows
    // must say different things, which is the whole point.
    expect(find.text('ENCRYPTED · Key unreachable'), findsOneWidget);
    expect(find.text('DISABLED'), findsOneWidget);
    expect(
      find.textContaining('cannot be decrypted'),
      findsOneWidget,
      reason: 'the sync card must say why the button is dead',
    );
  });

  testWidgets('an unconfigured install still reads DISABLED with no alarm', (
    WidgetTester tester,
  ) async {
    // The other half of the pin: absent and unreadable are different facts and
    // must not converge on one message.
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

    expect(find.text('DISABLED'), findsNWidgets(2));
    expect(find.text('ENCRYPTED · Key unreachable'), findsNothing);
    expect(find.textContaining('cannot be decrypted'), findsNothing);
  });

  testWidgets('the sync button is inert and not painted as enabled', (
    WidgetTester tester,
  ) async {
    // It kept `disabledBackgroundColor: Console.green.withValues(alpha: 0.8)`
    // and black text, so a dead button was indistinguishable from a live one
    // and taps produced a ripple and nothing else.
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

    final Finder button = find.widgetWithText(
      ElevatedButton,
      'CONFIGURE SYNC',
    );
    expect(button, findsOneWidget);

    final ElevatedButton widget = tester.widget<ElevatedButton>(button);
    expect(widget.onPressed, isNull);
    // Asserting "not Console.green" would pass vacuously: the override was a
    // *derived* green (alpha 0.8), a different object that still reads as the
    // enabled colour on screen. What the fix removes is the override itself,
    // so the button falls back to the theme's disabled treatment.
    expect(
      widget.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      isNull,
      reason: 'a disabled action must not paint its own background',
    );
    expect(
      widget.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      isNull,
    );
  });

  testWidgets('the header trailing reads local only with no account', (
    WidgetTester tester,
  ) async {
    final SettingsController controller = buildSettingsController();
    await controller.initialize();
    await pumpConfig(tester, controller);

    expect(find.text('local only'), findsOneWidget);
  });

  testWidgets(
    'the header trailing follows the signed-in account, not a literal',
    (WidgetTester tester) async {
      // The defect this pins: the header used to say `local only`
      // unconditionally while the account card said SIGNED IN right below it.
      final _FakeAuthGateway gateway = _FakeAuthGateway(
        currentIdentity: const AuthIdentity(
          id: 'owner-id',
          email: 'owner@example.com',
        ),
      );
      final AuthController auth = AuthController(gateway)..initialize();
      addTearDown(auth.dispose);
      addTearDown(gateway.changes.close);

      final SettingsController controller = buildSettingsController();
      await controller.initialize();
      await pumpConfig(tester, controller, authController: auth);

      expect(find.text('owner@example.com'), findsOneWidget);
      expect(find.text('local only'), findsNothing);

      // Signing out — an identity change `ConfigTab` was not previously
      // listening for at all, since `AuthController` is not part of the
      // shell's merged `Listenable`.
      gateway.changes.add(null);
      // A broadcast stream event needs a microtask turn to be delivered.
      await tester.pump();
      await tester.pump();

      expect(find.text('local only'), findsOneWidget);
      expect(find.text('owner@example.com'), findsNothing);
    },
  );

  testWidgets(
    'the QR pairing button belongs to the legacy section, not the R2 card',
    (WidgetTester tester) async {
      // It used to be `Expanded(child: ElevatedButton...)` inside the R2
      // card's own `Column`, which made a Turso-only install's pairing
      // button look like an R2-specific feature.
      final SettingsController controller = buildSettingsController();
      await controller.initialize();
      await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

      final Finder qrButton = find.widgetWithText(
        ElevatedButton,
        'PAIR DEVICE VIA QR CODE',
      );
      expect(qrButton, findsOneWidget);

      final Finder r2Card = find.ancestor(
        of: find.text('CLOUDFLARE R2'),
        matching: find.byType(ConsoleCard),
      );
      expect(r2Card, findsOneWidget);
      expect(
        find.descendant(of: r2Card, matching: qrButton),
        findsNothing,
        reason: 'pairing configures both Turso and R2, so it cannot live '
            'inside the card for just one of them',
      );

      // Below both provider cards, not between the account and the section.
      final double qrTop = tester.getTopLeft(qrButton).dy;
      final double r2Bottom = tester.getBottomLeft(r2Card).dy;
      expect(qrTop, greaterThanOrEqualTo(r2Bottom));
    },
  );

  testWidgets(
    'Turso and R2 read as one demoted section under the Supabase account',
    (WidgetTester tester) async {
      final SettingsController controller = buildSettingsController();
      await controller.initialize();
      await pumpConfig(tester, controller, initialCategory: ConfigCategory.sync);

      // One page-level header for both providers, not three peer headers.
      expect(find.text('LEGACY SYNC'), findsOneWidget);
      expect(find.text('CLOUD SYNC'), findsNothing);
      expect(find.text('TURSO CLOUD SYNC'), findsNothing);
      expect(find.text('CLOUDFLARE R2 MEDIA SYNC'), findsNothing);
      // Demoted to in-card labels instead.
      expect(find.text('TURSO'), findsOneWidget);
      expect(find.text('CLOUDFLARE R2'), findsOneWidget);
      // The account card is still the first thing on the sub-tab.
      expect(find.text('SUPABASE ACCOUNT'), findsOneWidget);
      final double accountTop = tester
          .getTopLeft(find.text('SUPABASE ACCOUNT'))
          .dy;
      final double legacyTop = tester.getTopLeft(find.text('LEGACY SYNC')).dy;
      expect(accountTop, lessThan(legacyTop));
    },
  );

  test('a credential change invalidates the last sync report', () {
    const AppSettings synced = AppSettings(
      r2Endpoint: 'https://account.r2.cloudflarestorage.com',
      r2Bucket: 'captures',
      r2AccessKeyId: 'access-key',
      r2SecretAccessKey: 'old-secret',
    );
    const AppSettings changed = AppSettings(
      r2Endpoint: 'https://account.r2.cloudflarestorage.com',
      r2Bucket: 'captures',
      r2AccessKeyId: 'access-key',
      r2SecretAccessKey: 'new-secret',
    );
    final CloudSyncReport report = CloudSyncReport(
      completedAt: DateTime(2026),
      configurationFingerprint:
          RecordingsController.cloudSyncConfigurationFingerprint(synced),
    );

    expect(
      report.matchesConfiguration(
        RecordingsController.cloudSyncConfigurationFingerprint(changed),
      ),
      isFalse,
    );
  });
}

import 'dart:io';

import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/transcript_cleaner.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/cleanup_proposal.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/cleanup_section.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/presentation/enrichment_context_section.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const String _raw = 'eee so we need to uh call the client';
const String _clean = 'So we need to call the client.';

Recording _proposed({String transcript = _raw}) => Recording.fromJson(
  makeRecording(id: 'a', transcript: transcript).toJson()
    ..['cleanup'] = CleanupProposal(
      text: _clean,
      source: CleanupProposal.fingerprint(_raw),
    ).toJson(),
);

class _FakeCleaner implements TranscriptCleaner {
  @override
  Future<String> cleanUp(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async => _clean;
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('cleanup_ui_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpSection(
    WidgetTester tester,
    Recording recording, {
    VoidCallback? onAccept,
    VoidCallback? onReject,
    VoidCallback? onCleanUp,
    String? acceptBlockedReason,
  }) async {
    await tester.pumpWidget(
      hostTab(
        () => CleanupSection(
          recording: recording,
          cleaning: false,
          onAccept: onAccept,
          onReject: onReject,
          onCleanUp: onCleanUp,
          acceptBlockedReason: acceptBlockedReason,
        ),
      ),
    );
  }

  /// The [TextSpan] children of the diff, by the words they carry.
  Map<String, TextStyle?> diffStyles(WidgetTester tester) {
    final RichText rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((RichText r) => r.text.toPlainText().contains('client'));
    final Map<String, TextStyle?> styles = <String, TextStyle?>{};
    rich.text.visitChildren((InlineSpan span) {
      if (span is TextSpan && span.text != null) {
        styles[span.text!.trim()] = span.style;
      }
      return true;
    });
    return styles;
  }

  group('CleanupSection', () {
    testWidgets('shows the proposal as a diff and accepts or rejects it', (
      WidgetTester tester,
    ) async {
      int accepted = 0;
      int rejected = 0;
      await pumpSection(
        tester,
        _proposed(),
        onAccept: () => accepted++,
        onReject: () => rejected++,
      );

      expect(find.text('PROPOSED'), findsOneWidget);
      final Map<String, TextStyle?> styles = diffStyles(tester);
      expect(
        styles['eee so']?.decoration,
        TextDecoration.lineThrough,
        reason: 'a removed filler is struck through, not silently gone',
      );
      expect(styles['So']?.decoration, isNot(TextDecoration.lineThrough));

      await tester.tap(find.text(CleanupSection.acceptLabel));
      await tester.tap(find.text(CleanupSection.rejectLabel));
      expect(accepted, 1);
      expect(rejected, 1);
    });

    testWidgets('a stale proposal offers a new one instead of ACCEPT', (
      WidgetTester tester,
    ) async {
      int cleaned = 0;
      await pumpSection(
        tester,
        _proposed(transcript: 'edited since'),
        onAccept: () {},
        onReject: () {},
        onCleanUp: () => cleaned++,
      );

      expect(find.text('STALE'), findsOneWidget);
      expect(find.text(CleanupSection.acceptLabel), findsNothing);
      await tester.tap(find.text('CLEAN UP AGAIN'));
      expect(cleaned, 1);
    });

    testWidgets('an unsaved text edit blocks ACCEPT and says why', (
      WidgetTester tester,
    ) async {
      int accepted = 0;
      await pumpSection(
        tester,
        _proposed(),
        onAccept: () => accepted++,
        onReject: () {},
        acceptBlockedReason: 'Save or revert the text above first.',
      );

      await tester.tap(find.text(CleanupSection.acceptLabel));
      expect(accepted, 0);
      expect(find.text('Save or revert the text above first.'), findsOneWidget);
    });
  });

  group('in the queue editor', () {
    Future<RecordingsController> pumpEditor(
      WidgetTester tester,
      Recording seed,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[seed],
      );
      controller.transcriptCleaner = _FakeCleaner();
      await tester.pumpWidget(
        hostTab(() => QueueTab(controller: controller), listenable: controller),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      // The editor fades in; a tap before it lands misses.
      await tester.pump(const Duration(milliseconds: 300));
      return controller;
    }

    testWidgets('CLEAN UP proposes, and ACCEPT replaces the transcript', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = await pumpEditor(
        tester,
        makeRecording(id: 'a', transcript: _raw),
      );

      await tester.ensureVisible(find.text(CleanupSection.cleanUpLabel));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(CleanupSection.cleanUpLabel));
      await settleIo(tester);

      expect(controller.recordings.single.cleanup?.text, _clean);
      expect(controller.recordings.single.transcript, _raw);

      await tester.ensureVisible(find.text(CleanupSection.acceptLabel));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(CleanupSection.acceptLabel));
      await settleIo(tester);

      expect(controller.recordings.single.transcript, _clean);
      expect(controller.recordings.single.cleanup, isNull);
    });

    testWidgets('a typed note has no CLEAN UP button', (
      WidgetTester tester,
    ) async {
      await pumpEditor(
        tester,
        makeRecording(id: 'a', type: CaptureType.text, transcript: _raw),
      );

      expect(find.text(CleanupSection.cleanUpLabel), findsNothing);
    });
  });

  testWidgets('the Config switch turns auto clean-up on', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SettingsController settings = buildSettingsController();
    await settings.initialize();
    await tester.pumpWidget(
      hostTab(
        () => EnrichmentContextSection(controller: settings),
        listenable: settings,
      ),
    );
    await tester.pump();
    expect(settings.autoCleanup, isFalse);

    final Finder toggle = find.byKey(const ValueKey<String>('auto-cleanup'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await settleIo(tester);

    expect(settings.autoCleanup, isTrue);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_row.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

class _GatedTranscriptionService implements TranscriptionService {
  final Completer<void> gate = Completer<void>();
  bool called = false;

  @override
  Future<String> transcribe(File audioFile) async {
    called = true;
    await gate.future;
    return 'LATE RESULT';
  }
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('cancel_ui_test_'));
  tearDown(() {
    if (appDir.existsSync()) {
      appDir.deleteSync(recursive: true);
    }
  });

  testWidgets('RecordingCard renders elapsed duration and CANCEL ghost button', (
    WidgetTester tester,
  ) async {
    bool cancelCalled = false;
    final Recording recording = makeRecording(
      id: 'card_active',
      title: 'Transcribing voice note',
      status: RecordingStatus.transcribing,
    );

    await tester.pumpWidget(
      hostTab(
        () => RecordingCard(
          recording: recording,
          isPlaying: false,
          processingElapsed: const Duration(seconds: 12),
          onCancelProcessing: () => cancelCalled = true,
          onTogglePlay: () {},
          onOpen: () {},
          onRetry: () {},
          onEnrich: () {},
          onEdit: () {},
          onToggleProcessed: () {},
          onRoute: () {},
          onHandoff: () {},
        ),
      ),
    );
    await tester.pump();

    // Verify pulsing status pill contains elapsed time
    expect(find.text('TRANSCRIBING · 00:12'), findsOneWidget);

    // Verify CANCEL button is visible
    final Finder cancelButton = find.text('CANCEL');
    expect(cancelButton, findsOneWidget);

    // Tap cancel
    await tester.tap(cancelButton);
    await tester.pump();

    expect(cancelCalled, isTrue);
  });

  testWidgets('RecordingRow renders elapsed timer and cancel button when transcribing', (
    WidgetTester tester,
  ) async {
    bool cancelCalled = false;
    final Recording recording = makeRecording(
      id: 'row_active',
      title: 'Transcribing row',
      status: RecordingStatus.transcribing,
    );

    await tester.pumpWidget(
      hostTab(
        () => RecordingRow(
          recording: recording,
          focused: false,
          isEnriching: false,
          processingElapsed: const Duration(seconds: 7),
          onCancelProcessing: () => cancelCalled = true,
          onTap: () {},
          onToggleProcessed: () {},
        ),
      ),
    );
    await tester.pump();

    // ProcessingStrip on row shows elapsed time
    expect(find.text('TRANSCRIBING · 00:07'), findsOneWidget);

    final Finder cancelIcon = find.byIcon(Icons.close_rounded);
    expect(cancelIcon, findsOneWidget);

    await tester.tap(cancelIcon);
    await tester.pump();

    expect(cancelCalled, isTrue);
  });

  testWidgets('CaptureFocusView renders elapsed status pill in header and cancel action', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final File audioFile = File('${appDir.path}/focus_audio.m4a')
      ..writeAsStringSync('audio');
    final Recording recording = Recording(
      id: 'focus_active',
      filePath: audioFile.path,
      createdAt: DateTime.utc(2026, 9, 7),
      durationMs: 5000,
      sizeBytes: 100,
      status: RecordingStatus.saved,
      title: 'Active focus capture',
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: audioFile.path,
          type: CaptureType.audioRecording,
          createdAt: DateTime.utc(2026, 9, 7),
          sizeBytes: 100,
        ),
      ],
    );
    final _GatedTranscriptionService gated = _GatedTranscriptionService();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[recording],
      service: gated,
    );

    // Trigger processing and wait until gated service is in flight
    await tester.runAsync(() async {
      unawaited(controller.retryTranscription('focus_active'));
      while (!gated.called) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    await tester.pumpWidget(
      hostTab(
        () => Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => showCaptureFocusView(
              context,
              controller: controller,
              recordingId: 'focus_active',
            ),
            child: const Text('OPEN'),
          ),
        ),
        listenable: controller,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await tester.pump(const Duration(milliseconds: 200));

    // Status pill in header
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.textContaining('TRANSCRIBING'),
      ),
      findsOneWidget,
    );

    // Cancel action in actions bar
    final Finder cancelAction = find.byTooltip('Cancel processing');
    expect(cancelAction, findsOneWidget);

    await tester.tap(cancelAction);
    await tester.runAsync(() async {
      gated.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(controller.recordings.single.error, 'Cancelled by user');
  });

  testWidgets('QueueTab user can cancel in-flight request directly from card', (
    WidgetTester tester,
  ) async {
    final File audioFile = File('${appDir.path}/queue_audio.m4a')
      ..writeAsStringSync('audio');
    final Recording recording = Recording(
      id: 'queue_cancel',
      filePath: audioFile.path,
      createdAt: DateTime.utc(2026, 9, 7),
      durationMs: 5000,
      sizeBytes: 100,
      status: RecordingStatus.saved,
      title: 'In-flight card in queue',
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: audioFile.path,
          type: CaptureType.audioRecording,
          createdAt: DateTime.utc(2026, 9, 7),
          sizeBytes: 100,
        ),
      ],
    );
    final _GatedTranscriptionService gated = _GatedTranscriptionService();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[recording],
      service: gated,
    );

    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();

    // Start processing
    await tester.runAsync(() async {
      unawaited(controller.retryTranscription('queue_cancel'));
      while (!gated.called) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    // CANCEL button should be visible on the card
    final Finder cancelBtn = find.text('CANCEL');
    expect(cancelBtn, findsOneWidget);

    // Click cancel
    await tester.tap(cancelBtn);
    await tester.runAsync(() async {
      gated.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    // The item should now be in FAILED state with Cancelled by user error
    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(controller.recordings.single.error, 'Cancelled by user');
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.text('Cancelled by user'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
  });
}

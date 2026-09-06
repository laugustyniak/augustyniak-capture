import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/inline_video_player.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late Directory tempDir;
  late File videoFile;
  late File posterFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('video_widget_test_');
    videoFile = File('${tempDir.path}/sample.mp4');
    await videoFile.writeAsBytes(<int>[0, 0, 0, 20, 1, 2, 3]);

    posterFile = File('${tempDir.path}/sample.thumb.jpg');
    // A 1x1 JPEG byte payload
    await posterFile.writeAsBytes(<int>[
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
      0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01,
      0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09,
      0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7F, 0x00,
      0xFF, 0xD9
    ]);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> pumpPlayer(
    WidgetTester tester, {
    required File videoFile,
    File? posterFile,
    Duration? duration = const Duration(seconds: 45),
    String? title = 'Project Demo',
    VideoPlaybackController? controller,
    VoidCallback? onOpenExternal,
    bool compact = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: InlineVideoPlayer(
              videoFile: videoFile,
              posterFile: posterFile,
              duration: duration,
              title: title,
              controller: controller,
              onOpenExternal: onOpenExternal,
              compact: compact,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('InlineVideoPlayer Widget', () {
    testWidgets('renders poster image when poster exists', (
      WidgetTester tester,
    ) async {
      await pumpPlayer(
        tester,
        videoFile: videoFile,
        posterFile: posterFile,
        duration: const Duration(seconds: 60),
      );

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
      expect(find.text('00:00 / 01:00'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('renders fallback placeholder when poster is missing or null', (
      WidgetTester tester,
    ) async {
      await pumpPlayer(
        tester,
        videoFile: videoFile,
        posterFile: null,
        title: 'Walkthrough Video',
      );

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.text('Walkthrough Video'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    });

    testWidgets('renders error view when video file is missing', (
      WidgetTester tester,
    ) async {
      final File missing = File('${tempDir.path}/not_found.mp4');
      await pumpPlayer(tester, videoFile: missing);

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.textContaining('Video file is missing'), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    });

    testWidgets('play/pause button toggles playback state', (
      WidgetTester tester,
    ) async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 30),
      );

      await pumpPlayer(
        tester,
        videoFile: videoFile,
        controller: controller,
        duration: const Duration(seconds: 30),
      );

      expect(controller.isPlaying, isFalse);
      expect(find.byTooltip('Play video'), findsOneWidget);

      // Tap play button in controls
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();

      expect(controller.isPlaying, isTrue);
      expect(find.byTooltip('Pause video'), findsOneWidget);

      // Tap pause button
      await tester.tap(find.byTooltip('Pause video'));
      await tester.pump();

      expect(controller.isPlaying, isFalse);
      expect(find.byTooltip('Play video'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('seeking via Slider updates position', (
      WidgetTester tester,
    ) async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 100),
      );

      await pumpPlayer(
        tester,
        videoFile: videoFile,
        controller: controller,
        duration: const Duration(seconds: 100),
      );

      expect(controller.position, Duration.zero);

      // Programmatic seek
      await controller.seek(const Duration(seconds: 40));
      await tester.pump();

      expect(find.text('00:40 / 01:40'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('mute toggle button changes mute state', (
      WidgetTester tester,
    ) async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 30),
      );

      await pumpPlayer(
        tester,
        videoFile: videoFile,
        controller: controller,
      );

      expect(controller.isMuted, isFalse);
      expect(find.byTooltip('Mute video'), findsOneWidget);

      await tester.tap(find.byTooltip('Mute video'));
      await tester.pump();

      expect(controller.isMuted, isTrue);
      expect(find.byTooltip('Unmute video'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('external open button triggers onOpenExternal', (
      WidgetTester tester,
    ) async {
      bool opened = false;
      await pumpPlayer(
        tester,
        videoFile: videoFile,
        onOpenExternal: () => opened = true,
      );

      expect(find.byTooltip(RecordingCard.openVideoLabel), findsWidgets);
      await tester.tap(find.byTooltip(RecordingCard.openVideoLabel).first);
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('tapping center play overlay starts playback', (
      WidgetTester tester,
    ) async {
      final VideoPlaybackController controller = VideoPlaybackController(
        videoFile: videoFile,
        duration: const Duration(seconds: 30),
      );

      await pumpPlayer(
        tester,
        videoFile: videoFile,
        controller: controller,
      );

      expect(controller.isPlaying, isFalse);

      // Tap on the video center overlay
      await tester.tap(find.bySemanticsLabel('Play video screen'));
      await tester.pump();

      expect(controller.isPlaying, isTrue);

      await controller.pause();
      controller.dispose();
    });
  });

  group('Video playback integration', () {
    testWidgets('InlineVideoPlayer.forRecording renders video recording details', (
      WidgetTester tester,
    ) async {
      final Recording videoRecording = makeRecording(
        id: 'rec_video_1',
        type: CaptureType.video,
        filePath: videoFile.path,
        thumbPath: posterFile.path,
        title: 'Sprint Demo Video',
        durationMs: 45000,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: InlineVideoPlayer.forRecording(
                recording: videoRecording,
                onOpenExternal: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(InlineVideoPlayer), findsOneWidget);
      expect(find.text('00:00 / 00:45'), findsOneWidget);
    });

    testWidgets('CaptureFocusView renders InlineVideoPlayer for video items', (
      WidgetTester tester,
    ) async {
      final Recording videoRecording = makeRecording(
        id: 'rec_video_focus',
        type: CaptureType.video,
        filePath: videoFile.path,
        thumbPath: posterFile.path,
        title: 'Sprint Demo Focus',
        durationMs: 90000,
        transcript: 'Transcript of the demo.',
      );

      final RecordingsController controller = await buildRecordingsController(
        tempDir,
        seed: <Recording>[videoRecording],
      );

      await tester.pumpWidget(
        hostTab(
          () => Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () => showCaptureFocusView(
                context,
                controller: controller,
                recordingId: 'rec_video_focus',
              ),
              child: const Text('OPEN FOCUS'),
            ),
          ),
          listenable: controller,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('OPEN FOCUS'));
      await tester.pumpAndSettle();

      expect(find.byType(InlineVideoPlayer), findsOneWidget);
      expect(find.text('00:00 / 01:30'), findsOneWidget);
    });
  });
}

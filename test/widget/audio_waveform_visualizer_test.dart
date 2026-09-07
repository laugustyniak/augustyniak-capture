import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/audio_waveform_visualizer.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';

import '../support/harness.dart';

void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'audio_waveform_test_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  test('generateWaveformSamples creates deterministic normalized samples', () {
    final List<double> samples1 = generateWaveformSamples('recording-abc', count: 36);
    final List<double> samples2 = generateWaveformSamples('recording-abc', count: 36);

    expect(samples1, hasLength(36));
    expect(samples1, equals(samples2));

    for (final double sample in samples1) {
      expect(sample, greaterThanOrEqualTo(0.2));
      expect(sample, lessThanOrEqualTo(1.0));
    }
  });

  testWidgets('AudioWaveformVisualizer renders CustomPaint and handles tap/drag seek', (
    WidgetTester tester,
  ) async {
    final List<double> samples = generateWaveformSamples('test-123', count: 30);
    double? soughtRatio;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 30,
              child: AudioWaveformVisualizer(
                progress: 0.25,
                samples: samples,
                onSeek: (double ratio) => soughtRatio = ratio,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AudioWaveformVisualizer), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // Tap at center (50% = 0.5)
    await tester.tap(find.byType(AudioWaveformVisualizer));
    await tester.pump();

    expect(soughtRatio, isNotNull);
    expect(soughtRatio, closeTo(0.5, 0.05));

    // Drag from 25% to 75%
    await tester.drag(find.byType(AudioWaveformVisualizer), const Offset(100, 0));
    await tester.pump();
    expect(soughtRatio, isNotNull);
  });

  testWidgets('CaptureFocusView embeds AudioWaveformVisualizer for audio recordings', (
    WidgetTester tester,
  ) async {
    final File source = File('${appDir.path}/test_audio.m4a')
      ..writeAsBytesSync(<int>[1, 2, 3]);

    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[
        makeRecording(
          id: 'audio-rec',
          title: 'My Recording',
          type: CaptureType.audioRecording,
          filePath: source.path,
          status: RecordingStatus.completed,
          durationMs: 60000,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => showCaptureFocusView(
              context,
              controller: controller,
              recordingId: 'audio-rec',
            ),
            child: const Text('OPEN FOCUS'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OPEN FOCUS'));
    await tester.pumpAndSettle();

    expect(find.byType(AudioWaveformVisualizer), findsOneWidget);
    expect(find.text('00:00 / 01:00'), findsOneWidget);
    expect(find.text('1x'), findsOneWidget);

    // Seek via waveform tap
    await tester.tap(find.byType(AudioWaveformVisualizer));
    await tester.pumpAndSettle();

    expect(controller.playbackPosition, isNot(Duration.zero));
  });

  testWidgets('AudioWaveformVisualizer gracefully handles empty samples and zero sizes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 0,
              height: 0,
              child: AudioWaveformVisualizer(
                progress: 0.5,
                samples: <double>[],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AudioWaveformVisualizer), findsOneWidget);
  });
}

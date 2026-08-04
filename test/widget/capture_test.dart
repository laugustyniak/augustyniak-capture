import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_dock.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/recordings/presentation/text_note_sheet.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

import '../support/harness.dart';

/// Grants the microphone and actually writes the file `start` was handed, so
/// `stopRecording` reaches its verify-then-persist path instead of failing on a
/// missing source. Everything else is a no-op — notably `onAmplitudeChanged`,
/// which falls through to `noSuchMethod` and returns a `Future`, not a
/// `Stream`: that is exactly the platform-without-a-meter case the controller
/// has to survive.
class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    // Synchronous on purpose: a tap-driven test drives this from inside the
    // fake-async zone, where a real async write has nothing to pump it.
    File(path).writeAsBytesSync(<int>[1, 2, 3], flush: true);
    _path = path;
  }

  @override
  Future<String?> stop() async => _path;

  String? _path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// A recorder that *does* report amplitude, which the plain fake above never
/// does. That gap is why the level meter shipped throwing on every sample: the
/// listener it dies in is only ever reached under a real microphone, so the
/// whole suite passed while the bars sat flat and the console filled with
/// `Cannot remove from a fixed-length list`.
class _MeteringRecorder extends _GrantingRecorder {
  final StreamController<Amplitude> levels =
      StreamController<Amplitude>.broadcast();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => levels.stream;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_capture_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  /// Lets filesystem work started from inside the fake-async zone (a button
  /// tap) actually finish: `runAsync` hands the isolate back to the real event
  /// loop, and the following `pump` flushes the microtasks that completion
  /// queued up.
  Future<void> settleIo(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  RecordingsController buildController({AudioRecorder? recorder}) {
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: recorder ?? _GrantingRecorder(),
      player: _FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// The meter's bars, left to right. Identified by their animation duration
  /// and tight height — the two things no other animated box on this screen
  /// shares — rather than by the private widget that owns them.
  List<double> barHeights(WidgetTester tester) => tester
      .widgetList<AnimatedContainer>(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is AnimatedContainer &&
              widget.duration == const Duration(milliseconds: 120) &&
              widget.constraints?.hasTightHeight == true,
        ),
      )
      .map((AnimatedContainer bar) => bar.constraints!.maxHeight)
      .toList();

  group('CaptureDock', () {
    testWidgets('the record button starts a recording', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = buildController();
      await tester.pumpWidget(
        hostTab(
          () => CaptureDock(controller: controller, onOpenCaptureMenu: () {}),
          listenable: controller,
        ),
      );

      await tester.tap(find.bySemanticsLabel('Start recording'));
      await settleIo(tester);

      expect(controller.isRecording, isTrue);

      // Stop before the test ends: an open capture leaves the 250 ms elapsed
      // timer pending, which the binding reports as a leak.
      await tester.runAsync(controller.stopRecording);
      await settleIo(tester);
    });

    testWidgets('the secondary button opens the capture menu', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = buildController();
      int opened = 0;
      await tester.pumpWidget(
        hostTab(
          () => CaptureDock(
            controller: controller,
            onOpenCaptureMenu: () => opened++,
          ),
          listenable: controller,
        ),
      );

      await tester.tap(find.bySemanticsLabel('New note or upload'));
      await tester.pump();

      expect(opened, 1);
    });
  });

  group('RecordingView', () {
    testWidgets('states what is being written and how far the pipeline is', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = buildController();
      await tester.runAsync(controller.startRecording);

      await tester.pumpWidget(
        hostTab(
          () => RecordingView(controller: controller),
          listenable: controller,
        ),
      );
      await tester.pump();

      expect(find.text('REC'), findsOneWidget);
      expect(find.text('AAC-LC · 16 kHz · mono · 64 kbps'), findsOneWidget);
      expect(find.text('recording → .m4a'), findsOneWidget);
      expect(find.text('persist recordings.json (atomic)'), findsOneWidget);
      // The guarantee is stated on the screen where it matters most — and now
      // names the one action that is exempt from it.
      expect(
        find.textContaining('a processing failure never deletes it'),
        findsOneWidget,
      );

      await tester.runAsync(controller.stopRecording);
      await settleIo(tester);
    });

    testWidgets('DISCARD asks first, and cancelling keeps recording', (
      WidgetTester tester,
    ) async {
      final _GrantingRecorder recorder = _GrantingRecorder();
      final RecordingsController controller = buildController(
        recorder: recorder,
      );
      await tester.runAsync(controller.startRecording);

      await tester.pumpWidget(
        hostTab(
          () => RecordingView(controller: controller),
          listenable: controller,
        ),
      );
      await tester.pump();

      await tester.tap(find.bySemanticsLabel(RecordingView.discardLabel));
      await tester.pump();
      expect(find.text('Discard this recording?'), findsOneWidget);

      await tester.tap(find.text('CANCEL'));
      await settleIo(tester);

      // Backing out of the dialog is not a decision about the take.
      expect(controller.isRecording, isTrue);
      expect(File(recorder._path!).existsSync(), isTrue);

      await tester.runAsync(controller.stopRecording);
      await settleIo(tester);
    });

    testWidgets('confirming DISCARD deletes the take and indexes nothing', (
      WidgetTester tester,
    ) async {
      final _GrantingRecorder recorder = _GrantingRecorder();
      final RecordingsController controller = buildController(
        recorder: recorder,
      );
      await tester.runAsync(controller.startRecording);
      final String path = recorder._path!;

      await tester.pumpWidget(
        hostTab(
          () => RecordingView(controller: controller),
          listenable: controller,
        ),
      );
      await tester.pump();

      await tester.tap(find.bySemanticsLabel(RecordingView.discardLabel));
      await tester.pump();
      await tester.tap(find.text('DISCARD'));
      await settleIo(tester);

      expect(controller.isRecording, isFalse);
      expect(controller.recordings, isEmpty);
      expect(File(path).existsSync(), isFalse);
    });

    testWidgets('SAVE stops the recorder and persists the capture', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = buildController();
      await tester.runAsync(controller.startRecording);

      await tester.pumpWidget(
        hostTab(
          () => RecordingView(controller: controller),
          listenable: controller,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('SAVE'));
      // Not `pumpAndSettle`: the REC pill and the pipeline dot pulse forever,
      // so "no frames scheduled" is a state this screen never reaches.
      await settleIo(tester);

      expect(controller.isRecording, isFalse);
      expect(controller.recordings, hasLength(1));
      // Measured during the same check that proved the file is non-empty.
      expect(controller.recordings.single.sizeBytes, 3);
      expect(controller.error, isNull);
    });

    testWidgets('the meter scrolls in the levels the recorder reports', (
      WidgetTester tester,
    ) async {
      final _MeteringRecorder recorder = _MeteringRecorder();
      addTearDown(recorder.levels.close);
      final RecordingsController controller = buildController(
        recorder: recorder,
      );
      await tester.runAsync(controller.startRecording);

      await tester.pumpWidget(
        hostTab(
          () => RecordingView(controller: controller),
          listenable: controller,
        ),
      );
      await tester.pump();

      // Silence: 33 bars, all at the resting height.
      expect(barHeights(tester), hasLength(33));
      expect(barHeights(tester).toSet(), <double>{6});

      // −5 dBFS is loud; the controller normalises it into the top of the meter.
      await tester.runAsync(() async {
        recorder.levels.add(Amplitude(current: -5, max: 0));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();

      // The bug this covers threw here, on every single sample, and left the
      // meter flat for the whole recording.
      expect(tester.takeException(), isNull);

      final List<double> heights = barHeights(tester);
      expect(heights, hasLength(33)); // the window never grows or shrinks
      expect(heights.last, greaterThan(6)); // newest sample on the right
      expect(heights.first, 6); // and the history scrolled rather than filled

      await tester.runAsync(controller.stopRecording);
      await settleIo(tester);
    });

    testWidgets('a recorder that reports no level still records', (
      WidgetTester tester,
    ) async {
      final RecordingsController controller = buildController();

      // `_GrantingRecorder` has no amplitude stream; the meter must degrade to
      // a flat line rather than taking the capture down with it.
      await tester.runAsync(controller.startRecording);

      expect(controller.isRecording, isTrue);
      expect(controller.levelTicker.value, 0);

      await tester.runAsync(controller.stopRecording);
      await settleIo(tester);
    });
  });

  group('TextNoteSheet', () {
    /// Opens the sheet on a real route so `Navigator.pop` has somewhere to go,
    /// and hands whatever it popped to [onResult].
    Future<void> openSheet(
      WidgetTester tester, {
      void Function(String?)? onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  final String? body = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (BuildContext _) => const TextNoteSheet(),
                  );
                  onResult?.call(body);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty note cannot be saved', (WidgetTester tester) async {
      await openSheet(tester);

      expect(find.text('0 chars'), findsOneWidget);
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();

      // Still open: the disabled button swallowed the tap.
      expect(find.text('New text note'), findsOneWidget);
    });

    testWidgets('typing enables save and returns the body', (
      WidgetTester tester,
    ) async {
      String? saved;
      bool popped = false;
      await openSheet(
        tester,
        onResult: (String? body) {
          saved = body;
          popped = true;
        },
      );

      await tester.enterText(find.byType(TextField), 'ship it');
      await tester.pumpAndSettle();
      expect(find.text('7 chars'), findsOneWidget);

      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();

      expect(find.text('New text note'), findsNothing);
      expect(popped, isTrue);
      expect(saved, 'ship it');
    });

    testWidgets('the sheet says the note never leaves the device', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);

      expect(find.text('NO NETWORK'), findsOneWidget);
      expect(find.text('.txt → verify → index → passthrough'), findsOneWidget);
    });
  });
}

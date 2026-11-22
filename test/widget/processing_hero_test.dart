import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:augustyniak_capture/features/recordings/presentation/processing_hero.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/animation_speed.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/settings/presentation/animation_speed_scope.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_orb/augustyniak_orb.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import '../support/harness.dart';

class _WritingRecorder implements AudioRecorder {
  String? _path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsBytesSync(<int>[1, 2, 3], flush: true);
    _path = path;
  }

  @override
  Future<String?> stop() async => _path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _GatedTranscription implements TranscriptionService {
  final Completer<void> started = Completer<void>();
  final Completer<String> release = Completer<String>();

  /// Polls rather than awaits: if the drain never reaches the service the
  /// test fails on its assertions instead of hanging.
  Future<void> waitStarted() async {
    for (int i = 0; i < 100 && !started.isCompleted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<String> transcribe(File audioFile) {
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('capture_hero_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  group('ProcessingHero.appliesTo', () {
    test('shows while there is no transcript, not once there is one', () {
      expect(
        ProcessingHero.appliesTo(
          makeRecording(id: 'a', status: RecordingStatus.transcribing),
          enriching: false,
        ),
        isTrue,
      );
      expect(
        ProcessingHero.appliesTo(
          makeRecording(id: 'a', status: RecordingStatus.pendingTranscription),
          enriching: false,
        ),
        isTrue,
      );
      expect(
        ProcessingHero.appliesTo(
          makeRecording(
            id: 'a',
            status: RecordingStatus.transcribing,
            transcript: 'hello',
          ),
          enriching: false,
        ),
        isFalse,
      );
    });

    test('shows while enriching a capture with no rewrite yet', () {
      final Recording bare = makeRecording(id: 'a', transcript: 'hello');
      expect(ProcessingHero.appliesTo(bare, enriching: true), isTrue);
      expect(
        ProcessingHero.appliesTo(
          makeRecording(id: 'a', transcript: 'hello', summary: 'short'),
          enriching: true,
        ),
        isFalse,
      );
      expect(ProcessingHero.appliesTo(bare, enriching: false), isFalse);
    });
  });

  testWidgets('the hero is a compact banner, not a screen-filling scene', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      hostTab(
        () => ListView(children: <Widget>[ProcessingHero(enriching: false)]),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.getSize(find.byType(ProcessingHero)).height,
      lessThanOrEqualTo(ProcessingHero.height),
    );
    expect(ProcessingHero.height, lessThanOrEqualTo(140));
    expect(find.text(ProcessingStrip.transcribingLabel), findsOneWidget);
  });

  testWidgets('pausing and resuming the scene controls its clock', (
    WidgetTester tester,
  ) async {
    const Key sceneKey = Key('scene');
    Future<void> pumpScene({required bool paused}) => tester.pumpWidget(
      hostTab(
        () => ProcessingScene(
          key: sceneKey,
          height: 240,
          paused: paused,
          semanticsLabel: 'Recording in progress',
        ),
      ),
    );

    await pumpScene(paused: false);
    await tester.pump(const Duration(milliseconds: 300));
    final dynamic state = tester.state(find.byType(OrbScene));
    final double running = state.debugSeconds as double;

    await pumpScene(paused: true);
    await tester.pump(const Duration(milliseconds: 500));
    final double paused = state.debugSeconds as double;
    expect(paused, running);

    await pumpScene(paused: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugSeconds as double, isNot(paused));
  });

  testWidgets('the scene runs at the speed chosen above the navigator', (
    WidgetTester tester,
  ) async {
    double speedOf() =>
        tester.widget<OrbScene>(find.byType(OrbScene)).preset.tuning.speed;
    Widget scene() =>
        ProcessingScene(height: 240, semanticsLabel: 'Transcribing in progress');

    await tester.pumpWidget(hostTab(scene));
    await tester.pump();
    expect(speedOf(), AnimationSpeed.calm.factor);

    await tester.pumpWidget(
      AnimationSpeedScope(speed: AnimationSpeed.drift, child: hostTab(scene)),
    );
    await tester.pump();
    expect(speedOf(), AnimationSpeed.drift.factor);

    await tester.pumpWidget(
      AnimationSpeedScope(speed: AnimationSpeed.original, child: hostTab(scene)),
    );
    await tester.pump();
    expect(speedOf(), 1);
  });

  testWidgets('reduced motion renders a stable processing scene', (
    WidgetTester tester,
  ) async {
    const Key sceneKey = Key('reduced-scene');
    await tester.pumpWidget(
      hostTab(
        () => Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: ProcessingScene(
              key: sceneKey,
              height: 240,
              semanticsLabel: 'Transcribing in progress',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final dynamic state = tester.state(find.byType(OrbScene));
    final double before = state.debugSeconds as double;

    await tester.pump(const Duration(milliseconds: 500));

    // The same still frame at any speed: t = seconds * speed / period.
    expect(before, closeTo(0.18 * 12 / AnimationSpeed.calm.factor, 1e-9));
    expect(state.debugSeconds as double, before);
  });

  testWidgets('a new voice note stays on the desk list, selection kept', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _GatedTranscription gate = _GatedTranscription();
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'old', title: 'Older capture', transcript: 'x'),
          makeRecording(
            id: 'done',
            title: 'Done capture',
            transcript: 'y',
            isProcessedByUser: true,
          ),
        ],
      ),
      transcriptionService: gate,
      recorder: _WritingRecorder(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
    await tester.tap(find.text('Older capture').first);
    await tester.pump();
    String shownId() => tester
        .widget<CaptureDetailPanel>(find.byType(CaptureDetailPanel))
        .recording
        .id;
    expect(shownId(), 'old');

    await tester.runAsync(() async {
      await controller.startRecording();
      await controller.stopRecording();
      await gate.waitStarted();
    });
    await tester.pump();

    final String added = controller.recordings.first.id;
    // The desk filter held and the previous selection stayed.
    expect(find.text('Done capture'), findsNothing);
    expect(shownId(), 'old');
    expect(find.byType(ProcessingHero), findsNothing);
    // The new row is in the list and shows its own processing indicator.
    final Finder row = find.byKey(ValueKey<String>(added));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(ScanLine)),
      findsOneWidget,
    );
    gate.release.complete('hello');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });

  testWidgets('a phone stays on the queue after a new voice note', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _GatedTranscription gate = _GatedTranscription();
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'old', title: 'Older capture', transcript: 'x'),
        ],
      ),
      transcriptionService: gate,
      recorder: _WritingRecorder(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();

    await tester.runAsync(() async {
      await controller.startRecording();
      await controller.stopRecording();
      await gate.waitStarted();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      Navigator.of(tester.element(find.byType(QueueTab))).canPop(),
      isFalse,
    );
    expect(find.byType(ProcessingHero), findsNothing);
    final Finder row = find.byKey(
      ValueKey<String>(controller.recordings.first.id),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(ScanLine)),
      findsOneWidget,
    );
    gate.release.complete('hello');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });

  testWidgets('the capture view offers RECORD for a new, unrelated capture', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'open', title: 'Open capture', transcript: 'x'),
        ],
      ),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _WritingRecorder(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    int recordTaps = 0;
    await tester.pumpWidget(
      hostTab(
        () => QueueTab(controller: controller, onRecordNew: () => recordTaps++),
        listenable: controller,
      ),
    );
    await tester.pump();
    final Finder record = find.descendant(
      of: find.byType(CaptureDetailPanel),
      matching: find.bySemanticsLabel(CaptureDetailPanel.recordNewLabel),
    );
    expect(record, findsOneWidget);

    await tester.tap(record);
    await tester.pump();

    expect(recordTaps, 1);
  });

  testWidgets('no RECORD button when the host cannot start a recording', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'open', title: 'Open capture', transcript: 'x'),
        ],
      ),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _WritingRecorder(),
      player: FakePlayer(),
      audioConfig: const AudioConfig(sampleRate: 16000, bitRate: 64000),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();

    expect(find.byType(CaptureDetailPanel), findsOneWidget);
    expect(
      find.bySemanticsLabel(CaptureDetailPanel.recordNewLabel),
      findsNothing,
    );
  });
}

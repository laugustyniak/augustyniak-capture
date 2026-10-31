import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/capture_focus_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/processing_hero.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/domain/audio_config.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/material.dart';
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

  testWidgets('the hero fills at least half of the screen height', (
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
      greaterThanOrEqualTo(450),
    );
  });

  testWidgets('a new voice note takes the focus and shows the hero', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'old', title: 'Older capture', transcript: 'x'),
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
    });
    await tester.pump();

    expect(shownId(), isNot('old'));
    expect(shownId(), controller.recordings.first.id);
  });
}

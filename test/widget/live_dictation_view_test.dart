import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/app/ui_kit.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_view.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/live_transcription.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import '../support/harness.dart';

class _StreamRecorder implements AudioRecorder {
  final StreamController<Uint8List> pcm = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      pcm.stream;

  @override
  Future<String?> stop() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _Session implements LiveTranscriptionSession {
  final StreamController<LiveTranscript> controller =
      StreamController<LiveTranscript>.broadcast();

  @override
  Stream<LiveTranscript> get updates => controller.stream;
  @override
  void addAudio(Uint8List pcm16le) {}
  @override
  Future<String> finish() async => '';
  @override
  Future<void> cancel() async {}
}

class _Service implements LiveTranscriptionService {
  _Service(this.session);
  final _Session session;
  @override
  bool get isAvailable => true;
  @override
  int get sampleRate => 16000;
  @override
  LiveTranscriptionSession start() => session;
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
    () => appDir = Directory.systemTemp.createTempSync('live_dictation_view_'),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  Future<RecordingsController> startLive(
    WidgetTester tester,
    _Session session,
  ) async {
    final RecordingsController controller = RecordingsController(
      repository: FakeRecordingsRepository(appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _StreamRecorder(),
      player: _FakePlayer(),
      liveTranscription: () => _Service(session),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.initialize);
    await tester.runAsync(controller.startRecording);
    await tester.pumpWidget(
      hostTab(
        () => RecordingView(controller: controller),
        listenable: controller,
      ),
    );
    await tester.pump();
    return controller;
  }

  /// Delivers [update] through the real stream and lets the listener run.
  Future<void> push(
    WidgetTester tester,
    _Session session,
    LiveTranscript update,
  ) async {
    await tester.runAsync(() async {
      session.controller.add(update);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  Future<void> leave(WidgetTester tester, RecordingsController c) async {
    await tester.runAsync(c.discardRecording);
    await tester.pump();
  }

  testWidgets('committed text is normal, the partial is greyed', (
    WidgetTester tester,
  ) async {
    final _Session session = _Session();
    final RecordingsController controller = await startLive(tester, session);

    expect(find.text('WAV PCM · mono · live dictation'), findsOneWidget);
    expect(find.text('recording → .wav (live)'), findsOneWidget);
    expect(find.text('listening…'), findsOneWidget);

    await push(
      tester,
      session,
      const LiveTranscript(committed: 'Dzień dobry', partial: 'wszystkim'),
    );

    final RichText rich = tester.widget<RichText>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is RichText && w.text.toPlainText().contains('Dzień dobry'),
      ),
    );
    final List<TextSpan> spans = <TextSpan>[];
    rich.text.visitChildren((InlineSpan span) {
      if (span is TextSpan) spans.add(span);
      return true;
    });
    final TextSpan committed = spans.firstWhere(
      (TextSpan s) => s.text == 'Dzień dobry',
    );
    final TextSpan partial = spans.firstWhere(
      (TextSpan s) => s.text == 'wszystkim',
    );
    expect(committed.style!.color, Console.text);
    expect(partial.style!.color, Console.dim);
    expect(find.text('live off: will transcribe after stop'), findsNothing);

    await leave(tester, controller);
  });

  testWidgets('a dead session says the take will be transcribed after stop', (
    WidgetTester tester,
  ) async {
    final _Session session = _Session();
    final RecordingsController controller = await startLive(tester, session);

    await push(
      tester,
      session,
      const LiveTranscript(committed: 'zapisane', failed: true),
    );

    expect(find.text('live off: will transcribe after stop'), findsOneWidget);
    expect(find.textContaining('zapisane'), findsOneWidget);
    expect(controller.isRecording, isTrue);

    await leave(tester, controller);
  });
}

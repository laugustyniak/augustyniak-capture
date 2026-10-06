import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/assistant_target.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_sender.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _FakeSender implements CaptureSender {
  _FakeSender({this.error, this.gate, this.dismiss = false});

  final Object? error;
  final Future<void>? gate;
  final bool dismiss;
  final List<({SendTarget target, String prompt})> calls =
      <({SendTarget target, String prompt})>[];

  @override
  Future<List<SendTarget>> availableTargets() async => const <SendTarget>[
    CopySendTarget(),
  ];

  @override
  Future<SendOutcome?> send(
    RoutedCapture capture,
    SendTarget target,
    String prompt,
  ) async {
    calls.add((target: target, prompt: prompt));
    if (gate != null) await gate;
    if (error != null) throw error!;
    if (dismiss) return null;
    return SendOutcome(
      record: RouteRecord(
        at: DateTime.utc(2026, 10, 6, 12),
        kind: RouteKind.assistant,
        target: 'ChatGPT · web',
      ),
      copiedToClipboard: true,
    );
  }
}

class _RecordingClosureLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

const SendTarget _chatgpt = AssistantSendTarget(AssistantTarget.chatgpt);

void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak-send-');
  });

  tearDown(() => appDir.deleteSync(recursive: true));

  Recording seeded() => makeRecording(id: 'r1', transcript: 'ask about X');

  test('canSend wants real text, not the card title stand-in', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
    );

    expect(controller.canSend(seeded()), isTrue);
    expect(
      controller.canSend(makeRecording(id: 'a', summary: 'the gist')),
      isTrue,
    );
    // Still transcribing: displayNameFor would answer "Voice note · 12:00",
    // which is not something to send anywhere.
    expect(controller.canSend(makeRecording(id: 'b', title: 'Idea')), isFalse);
    expect(
      controller.canSend(makeRecording(id: 'c', transcript: '  ')),
      isFalse,
    );
  });

  test(
    'a failed send leaves the item untouched and sets only the error',
    () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[seeded()],
        captureSender: _FakeSender(
          error: const AssistantUnavailableException(AssistantTarget.chatgpt),
        ),
      );

      final SendOutcome? outcome = await controller.send('r1', _chatgpt, 'p');

      expect(outcome, isNull);
      final Recording item = controller.recordings.single;
      expect(item.routes, isEmpty);
      expect(item.isProcessedByUser, isFalse);
      expect(controller.error, contains('ChatGPT'));
      expect(controller.isHandingOff('r1'), isFalse);
    },
  );

  test('a success appends the route and does not close the capture', () async {
    final _FakeSender sender = _FakeSender();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[seeded()],
      captureSender: sender,
    );

    final SendOutcome? outcome = await controller.send(
      'r1',
      _chatgpt,
      'edited prompt',
    );

    expect(outcome!.copiedToClipboard, isTrue);
    expect(sender.calls.single.prompt, 'edited prompt');
    final Recording item = controller.recordings.single;
    expect(item.routes.single.kind, RouteKind.assistant);
    expect(item.routes.single.target, 'ChatGPT · web');
    expect(item.isProcessedByUser, isFalse);
    expect(item.processedAt, isNull);
    expect(controller.error, isNull);
  });

  test('a dismissed share records nothing and is not an error', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[seeded()],
      captureSender: _FakeSender(dismiss: true),
    );

    final SendOutcome? outcome = await controller.send(
      'r1',
      const ShareSendTarget(),
      'p',
    );

    expect(outcome, isNull);
    expect(controller.recordings.single.routes, isEmpty);
    expect(controller.error, isNull);
  });

  test('a double call while in flight sends once', () async {
    final Completer<void> gate = Completer<void>();
    final _FakeSender sender = _FakeSender(gate: gate.future);
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[seeded()],
      captureSender: sender,
    );

    final Future<SendOutcome?> first = controller.send('r1', _chatgpt, 'p');
    final SendOutcome? second = await controller.send('r1', _chatgpt, 'p');
    expect(controller.isHandingOff('r1'), isTrue);
    gate.complete();
    final SendOutcome? firstResult = await first;

    expect(second, isNull);
    expect(firstResult, isNotNull);
    expect(sender.calls, hasLength(1));
    expect(controller.recordings.single.routes, hasLength(1));
  });

  test('a blank prompt falls back to the capture own text', () async {
    final _FakeSender sender = _FakeSender();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[seeded()],
      captureSender: sender,
    );

    await controller.send('r1', _chatgpt, '   ');

    expect(sender.calls.single.prompt, 'ask about X');
  });

  test('marking done after a send records a handoff closure', () async {
    final _RecordingClosureLog log = _RecordingClosureLog();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: <Recording>[seeded()],
      captureSender: _FakeSender(),
      closureLog: log,
    );

    await controller.send('r1', _chatgpt, 'p');
    expect(log.appended, isEmpty);
    await controller.toggleProcessed('r1');

    expect(controller.recordings.single.isProcessedByUser, isTrue);
    expect(log.appended.single.kind, ClosureKind.handoff);
  });

  test('sendTargets reads from the sender', () async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      captureSender: _FakeSender(),
    );

    expect(await controller.sendTargets(), <SendTarget>[
      const CopySendTarget(),
    ]);
  });

  test(
    'the prompt the sheet seeds exists without any project or handoff',
    () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
      );

      expect(controller.handoffPrompt(seeded()), 'ask about X');
    },
  );
}

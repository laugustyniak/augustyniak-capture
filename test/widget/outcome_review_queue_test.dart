import 'dart:io';

import 'package:augustyniak_capture/features/command/domain/outcome_review.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/queue_tab.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recording_card.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import '../support/harness.dart';

/// The spoken-review controls (#252) on the queue: the card's outcome line
/// carries LISTEN and REPLY, and the keyboard layer reaches the same two
/// actions on the selected row.

class _Speaker implements OutcomeSpeaker {
  _Speaker({this.available = true});
  final bool available;
  final List<String> spoken = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> speak(String text) async => spoken.add(text);
}

/// Grants the mic and writes a take wherever it is told to.
class _GrantingRecorder implements AudioRecorder {
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsStringSync('reply', flush: true);
    this.path = path;
  }

  @override
  Future<String?> stop() async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

RouteRecord _routed(CommandState? state) => RouteRecord(
  at: DateTime.utc(2026, 8, 15, 9),
  kind: RouteKind.command,
  target: 'studio · capture · plan-capture-01',
  outcome: state == null
      ? null
      : RouteOutcome(
          briefId: 'brief-1',
          state: state,
          checkedAt: DateTime.utc(2026, 8, 15, 9),
        ),
);

void main() {
  late Directory appDir;

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_outcome_review_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  final Finder listenAnswered = find.byKey(
    const ValueKey<String>('listen-outcome-answered'),
  );
  final Finder replyAnswered = find.byKey(
    const ValueKey<String>('reply-outcome-answered'),
  );

  Future<void> pumpQueue(
    WidgetTester tester,
    RecordingsController controller,
  ) async {
    await tester.pumpWidget(
      hostTab(() => QueueTab(controller: controller), listenable: controller),
    );
    await tester.pump();
  }

  List<Recording> seed() => <Recording>[
    makeRecording(
      id: 'answered',
      title: 'answered',
      routes: <RouteRecord>[_routed(CommandState.needsReview)],
    ),
    makeRecording(
      id: 'pending',
      title: 'pending',
      routes: <RouteRecord>[_routed(null)],
    ),
  ];

  testWidgets('LISTEN and REPLY sit on the outcome line and nowhere else', (
    WidgetTester tester,
  ) async {
    final _Speaker speaker = _Speaker();
    final _GrantingRecorder recorder = _GrantingRecorder();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: seed(),
      outcomeSpeaker: speaker,
      recorder: recorder,
    );
    await pumpQueue(tester, controller);

    expect(listenAnswered, findsOneWidget);
    expect(replyAnswered, findsOneWidget);
    // A delivery with no outcome yet has nothing to listen or reply to.
    expect(
      find.byKey(const ValueKey<String>('listen-outcome-pending')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reply-outcome-pending')),
      findsNothing,
    );

    await tester.tap(listenAnswered);
    await tester.pump();
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, contains('needs review'));

    await tester.tap(replyAnswered);
    await tester.pump();
    expect(controller.isRecording, isTrue);
    expect(controller.appendTargetId, 'answered');
    // A take is running, so a second reply is not offered.
    expect(replyAnswered, findsNothing);

    await tester.runAsync(controller.stopRecording);
    await tester.pump();
  });

  testWidgets('without a speaker, LISTEN is not offered', (
    WidgetTester tester,
  ) async {
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: seed(),
      outcomeSpeaker: _Speaker(available: false),
    );
    await pumpQueue(tester, controller);

    expect(listenAnswered, findsNothing);
    expect(replyAnswered, findsOneWidget);
    final RecordingCard card = tester.widget<RecordingCard>(
      find.ancestor(of: replyAnswered, matching: find.byType(RecordingCard)),
    );
    expect(card.onListenOutcome, isNull);
  });

  testWidgets('Ctrl/Cmd+Shift+L and +R act on the selected row', (
    WidgetTester tester,
  ) async {
    final _Speaker speaker = _Speaker();
    final _GrantingRecorder recorder = _GrantingRecorder();
    final RecordingsController controller = await buildRecordingsController(
      appDir,
      seed: seed(),
      outcomeSpeaker: speaker,
      recorder: recorder,
    );
    await pumpQueue(tester, controller);

    Future<void> chord(LogicalKeyboardKey modifier, LogicalKeyboardKey key) =>
        tester.sendKeyDownEvent(modifier).then((_) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(modifier);
          await tester.pump();
        });

    // Nothing selected: the chord acts on no row rather than a guessed one.
    await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyL);
    expect(speaker.spoken, isEmpty);

    // The second row has a delivery but no outcome — nothing to say.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await chord(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
    await chord(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyR);
    expect(speaker.spoken, isEmpty);
    expect(controller.isRecording, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyL);
    expect(speaker.spoken, hasLength(1));
    await chord(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
    expect(speaker.spoken, hasLength(2));

    await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyR);
    expect(controller.isRecording, isTrue);
    expect(controller.appendTargetId, 'answered');

    await tester.runAsync(controller.stopRecording);
    await tester.pump();
  });
}

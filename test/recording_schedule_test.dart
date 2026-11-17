import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/card_parts.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/recordings/presentation/schedule_dialog.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// Records what was appended, without a filesystem.
class _RecordingClosureLog implements ClosureLog {
  final List<ClosureEvent> appended = <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async => appended.add(event);
}

/// Fails every append, to prove a broken log never fails an occurrence.
class _FailingClosureLog implements ClosureLog {
  const _FailingClosureLog();

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async =>
      throw const FileSystemException('disk full');
}

void main() {
  final DateTime now = DateTime(2026, 11, 6, 10);

  group('Recording schedule fields', () {
    test('a scheduled item is off the desk until resurfaceAt passes', () {
      final Recording item = makeRecording(
        id: 'a',
      ).copyWith(resurfaceAt: now.add(const Duration(days: 1)));

      expect(item.isScheduledAt(now), isTrue);
      expect(item.isOnDeskAt(now), isFalse);
      expect(item.isOnDeskAt(now.add(const Duration(days: 2))), isTrue);
      expect(item.isScheduledAt(now.add(const Duration(days: 2))), isFalse);
    });

    test('an unscheduled open item is on the desk; a done one is not', () {
      expect(makeRecording(id: 'a').isOnDeskAt(now), isTrue);
      expect(
        makeRecording(id: 'b', isProcessedByUser: true).isOnDeskAt(now),
        isFalse,
      );
    });

    test('both fields round-trip through JSON', () {
      final Recording item = makeRecording(
        id: 'a',
      ).copyWith(resurfaceAt: DateTime.utc(2026, 11, 7, 9), repeatEveryDays: 7);
      final Recording back = Recording.fromJson(
        jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
      );
      expect(back.resurfaceAt, DateTime.utc(2026, 11, 7, 9));
      expect(back.repeatEveryDays, 7);
      expect(back.toJson(), item.toJson());
    });

    test('legacy JSON defaults both to null and re-serialises unchanged', () {
      final Map<String, dynamic> legacy = makeRecording(id: 'a').toJson();
      expect(legacy.containsKey('resurfaceAt'), isFalse);
      expect(legacy.containsKey('repeatEveryDays'), isFalse);

      final String before = jsonEncode(legacy);
      final Recording read = Recording.fromJson(
        jsonDecode(before) as Map<String, dynamic>,
      );
      expect(read.resurfaceAt, isNull);
      expect(read.repeatEveryDays, isNull);
      expect(jsonEncode(read.toJson()), before);
    });

    test('unreadable values degrade to null rather than throwing', () {
      final Map<String, dynamic> json = makeRecording(id: 'a').toJson()
        ..['resurfaceAt'] = 'not a date'
        ..['repeatEveryDays'] = 0;
      final Recording read = Recording.fromJson(json);
      expect(read.resurfaceAt, isNull);
      expect(read.repeatEveryDays, isNull);

      final Recording wrongTypes = Recording.fromJson(
        makeRecording(id: 'b').toJson()
          ..['resurfaceAt'] = 42
          ..['repeatEveryDays'] = 'weekly',
      );
      expect(wrongTypes.resurfaceAt, isNull);
      expect(wrongTypes.repeatEveryDays, isNull);
    });

    test('copyWith can clear both fields', () {
      final Recording item = makeRecording(
        id: 'a',
      ).copyWith(resurfaceAt: now, repeatEveryDays: 3);
      final Recording cleared = item.copyWith(
        clearResurfaceAt: true,
        clearRepeatEveryDays: true,
      );
      expect(cleared.resurfaceAt, isNull);
      expect(cleared.repeatEveryDays, isNull);
    });

    test('the meta label names the return date and the repeat', () {
      final Recording item = makeRecording(
        id: 'a',
      ).copyWith(resurfaceAt: DateTime(2026, 11, 7, 9), repeatEveryDays: 7);
      expect(
        scheduleLabelFor(item, now),
        'Returns 2026-11-07 09:00 · every 7 d',
      );
      expect(scheduleLabelFor(makeRecording(id: 'b'), now), isNull);
      // Once the date has passed the item is back; only the repeat remains.
      expect(
        scheduleLabelFor(item, DateTime(2026, 11, 8)),
        'Repeats every 7 d',
      );
    });
  });

  group('schedulePresets', () {
    test('next month clamps the 31st to the last day of that month', () {
      expect(
        schedulePresets(DateTime(2026, 1, 31, 15))['Next month'],
        DateTime(2026, 2, 28, 9),
      );
      expect(
        schedulePresets(DateTime(2026, 10, 31, 15))['Next month'],
        DateTime(2026, 11, 30, 9),
      );
      expect(
        schedulePresets(DateTime(2026, 12, 31, 15))['Next month'],
        DateTime(2027, 1, 31, 9),
      );
      expect(
        schedulePresets(DateTime(2028, 1, 30, 15))['Next month'],
        DateTime(2028, 2, 29, 9),
      );
    });

    test('next month keeps an ordinary day as it is', () {
      expect(
        schedulePresets(DateTime(2026, 11, 6, 15))['Next month'],
        DateTime(2026, 12, 6, 9),
      );
    });
  });

  group('countOffDesk', () {
    test('counts handed-off and waiting captures, not the open desk', () {
      final List<Recording> items = <Recording>[
        makeRecording(id: 'desk'),
        makeRecording(id: 'done').copyWith(isProcessedByUser: true),
        makeRecording(
          id: 'waiting',
        ).copyWith(resurfaceAt: now.add(const Duration(days: 1))),
        makeRecording(
          id: 'due',
        ).copyWith(resurfaceAt: now.subtract(const Duration(hours: 1))),
      ];

      expect(countOffDesk(items, now), 2);
    });
  });

  group('sync', () {
    test('the server row carries both fields and reads them back', () {
      final Recording item = makeRecording(
        id: 'a',
      ).copyWith(resurfaceAt: DateTime.utc(2026, 11, 7, 9), repeatEveryDays: 7);
      final Map<String, Object?> row = SyncRowCodec.recording(item);
      final Recording? back = SyncRowCodec.recordingFromRow(row);
      expect(back, isNotNull);
      expect(back!.resurfaceAt, DateTime.utc(2026, 11, 7, 9));
      expect(back.repeatEveryDays, 7);
    });

    test('an unscheduled row hashes as it did before the fields existed', () {
      final Map<String, Object?> row = SyncRowCodec.recording(
        makeRecording(id: 'a'),
      );
      final Map<String, Object?> payload =
          row['payload']! as Map<String, Object?>;
      expect(payload.containsKey('resurfaceAt'), isFalse);
      expect(payload.containsKey('repeatEveryDays'), isFalse);
    });
  });

  group('RecordingsController scheduling', () {
    late Directory appDir;

    setUp(() {
      appDir = Directory.systemTemp.createTempSync('augustyniak-schedule-');
    });

    tearDown(() => appDir.deleteSync(recursive: true));

    test('schedule takes an item off the desk and persists the date', () async {
      final FakeRecordingsRepository repository = FakeRecordingsRepository(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1')],
      );
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        repository: repository,
      );
      final DateTime at = DateTime.now().add(const Duration(days: 1));

      await controller.schedule('r1', at, repeatEveryDays: 7);

      final Recording item = controller.recordings.single;
      expect(item.resurfaceAt, at);
      expect(item.repeatEveryDays, 7);
      expect(item.isOnDeskAt(DateTime.now()), isFalse);
      expect(repository.saved.single.resurfaceAt, at);

      // A restart reads the same rows back from disk: the item is still off
      // the desk now, and on it once the clock passes the date.
      final RecordingsController restarted = await buildRecordingsController(
        appDir,
        seed: repository.saved,
      );
      final Recording reloaded = restarted.recordings.single;
      expect(reloaded.isOnDeskAt(DateTime.now()), isFalse);
      expect(reloaded.isOnDeskAt(at.add(const Duration(minutes: 1))), isTrue);
    });

    test('scheduling a done item reopens it to wait', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
            isProcessedByUser: true,
            processedAt: DateTime(2026, 11, 1),
          ),
        ],
      );
      final DateTime at = DateTime.now().add(const Duration(days: 7));

      await controller.schedule('r1', at);

      final Recording item = controller.recordings.single;
      expect(item.isProcessedByUser, isFalse);
      expect(item.processedAt, isNull);
      expect(item.resurfaceAt, at);
    });

    test('unschedule clears both fields and returns it to the desk', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(id: 'r1').copyWith(
            resurfaceAt: DateTime.now().add(const Duration(days: 3)),
            repeatEveryDays: 3,
          ),
        ],
      );

      await controller.unschedule('r1');

      final Recording item = controller.recordings.single;
      expect(item.resurfaceAt, isNull);
      expect(item.repeatEveryDays, isNull);
      expect(item.isOnDeskAt(DateTime.now()), isTrue);
    });

    test('a non-positive repeat is refused', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1')],
      );
      expect(
        () => controller.schedule('r1', DateTime.now(), repeatEveryDays: 0),
        throwsArgumentError,
      );
    });

    test(
      'DONE on a repeating item keeps it, moves resurfaceAt forward and logs a closure',
      () async {
        final _RecordingClosureLog log = _RecordingClosureLog();
        final RecordingsController controller = await buildRecordingsController(
          appDir,
          seed: <Recording>[
            makeRecording(
              id: 'r1',
            ).copyWith(resurfaceAt: DateTime(2026, 1, 1), repeatEveryDays: 7),
          ],
          closureLog: log,
        );
        final DateTime before = DateTime.now();

        await controller.toggleProcessed('r1');

        final Recording item = controller.recordings.single;
        expect(
          item.isProcessedByUser,
          isFalse,
          reason: 'a repeat never closes',
        );
        expect(item.repeatEveryDays, 7);
        final DateTime next = item.resurfaceAt!;
        expect(
          next.isAfter(before.add(const Duration(days: 6, hours: 22))),
          isTrue,
        );
        expect(
          next.isBefore(DateTime.now().add(const Duration(days: 7, hours: 2))),
          isTrue,
        );
        expect(item.isOnDeskAt(DateTime.now()), isFalse);
        expect(log.appended.length, 1);
        expect(log.appended.single.recordingId, 'r1');
        expect(log.appended.single.kind, ClosureKind.review);

        // DONE again before the next occurrence is due counts nothing and
        // leaves the date where it was: the work was not due yet.
        await controller.toggleProcessed('r1');
        expect(log.appended.length, 1);
        expect(controller.recordings.single.resurfaceAt, next);
        expect(controller.recordings.single.isProcessedByUser, isFalse);
      },
    );

    test('each due occurrence is its own closure', () async {
      final _RecordingClosureLog log = _RecordingClosureLog();
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[
          makeRecording(
            id: 'r1',
          ).copyWith(resurfaceAt: DateTime(2026, 1, 1), repeatEveryDays: 7),
          makeRecording(
            id: 'r2',
          ).copyWith(resurfaceAt: DateTime(2026, 1, 2), repeatEveryDays: 1),
        ],
        closureLog: log,
      );

      await controller.toggleProcessed('r1');
      await controller.toggleProcessed('r2');

      expect(log.appended.map((ClosureEvent e) => e.recordingId), <String>[
        'r1',
        'r2',
      ]);
    });

    test('a failing closure log never fails a repeat occurrence', () async {
      final RecordingsController controller = await buildRecordingsController(
        appDir,
        seed: <Recording>[makeRecording(id: 'r1').copyWith(repeatEveryDays: 1)],
        closureLog: const _FailingClosureLog(),
      );

      await controller.toggleProcessed('r1');

      expect(controller.recordings.single.resurfaceAt, isNotNull);
      expect(controller.error, isNull);
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Delays `saveAll` behind a gate the test controls, so a write started by
/// one mutation can be held open while another mutation is attempted
/// concurrently — reproducing finding I2 from the round-1 review of
/// `3a023fe..f1014cc`.
class _SlowRepository extends RecordingsRepository {
  _SlowRepository(Directory root)
    : super(directoryProvider: () async => root);

  Completer<void>? gate;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    await super.saveAll(recordings);
  }
}

Recording _item(String id, {String? title}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.utc(2026, 1, 1),
  durationMs: 1000,
  status: RecordingStatus.completed,
  title: title,
);

void main() {
  // The controller constructs a real recorder and player; stubbing their
  // channels keeps this off any actual device, as `index_durability_test.dart`
  // does.
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannel(name),
          (MethodCall call) async => null,
        );
  }

  late Directory dir;
  late _SlowRepository repository;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-sync-race-',
    );
    await File('${dir.path}/recordings.json').writeAsString(
      jsonEncode(<dynamic>[_item('local').toJson()]),
    );
    repository = _SlowRepository(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'a write already in flight and a concurrent applySyncedRecordings both '
    'land on disk — I2',
    () async {
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      // Hold every write open until the test releases it.
      repository.gate = Completer<void>();

      // Started, not awaited: runs synchronously up to `_persistAll`'s
      // `await mine`, where it suspends on the gate — the in-memory title
      // change has already landed in `_recordings` by this point.
      final Future<void> titleWrite = controller.setTitle('local', 'edited');

      // Started while the title write is still in flight: its merge reads
      // `_recordings` (title already changed) and adds the pulled row, then
      // its own `_persistAll` queues behind the title write's `_saveInFlight`.
      final Future<void> syncWrite = controller.applySyncedRecordings(
        <Recording>[_item('pulled')],
      );

      repository.gate!.complete();
      await titleWrite;
      await syncWrite;

      final List<Recording> onDisk = await RecordingsRepository(
        directoryProvider: () async => dir,
      ).loadAll();
      final Map<String, Recording> byId = <String, Recording>{
        for (final Recording r in onDisk) r.id: r,
      };
      expect(byId.keys, containsAll(<String>['local', 'pulled']));
      expect(
        byId['local']!.title,
        'edited',
        reason: 'the in-flight status/title transition must survive',
      );
    },
  );
}

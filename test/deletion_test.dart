import 'dart:async';
import 'dart:io';

import 'package:audivoa_core/features/processing/domain/processor.dart';
import 'package:audivoa_core/features/processing/domain/processor_registry.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:path/path.dart' as p;

/// The production repository, rooted in a temp directory instead of
/// `path_provider`'s app documents folder. Deliberately the real class: the two
/// things this suite is about — files actually leaving disk, and the shrinking-
/// index guard staying quiet — both live in that code, so a fake would assert
/// nothing.
class _TempRepository extends RecordingsRepository {
  _TempRepository(this.root);

  final Directory root;

  @override
  Future<Directory> recordingsDirectory() async {
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }
}

/// A disk that refuses to give a file up.
class _UndeletableRepository extends _TempRepository {
  _UndeletableRepository(super.root);

  @override
  Future<void> deleteArtifacts(Recording recording) async =>
      throw const FileSystemException('device is read-only');
}

/// Grants the mic and writes the file `start` was handed, so a capture reaches
/// its verify-then-persist path — and so `discardRecording` has a real file to
/// remove rather than a path that was never written.
class _GrantingRecorder implements AudioRecorder {
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsBytesSync(<int>[1, 2, 3], flush: true);
    this.path = path;
  }

  @override
  Future<String?> stop() async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Holds each job open until the test releases it, so an item can be deleted
/// while it is genuinely mid-flight.
class _GatedProcessor implements Processor {
  final List<Completer<void>> gates = <Completer<void>>[];
  final List<String> processed = <String>[];

  @override
  Future<String> process(Recording item) async {
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    processed.add(item.id);
    return 'text:${item.id}';
  }
}

/// Spin the real event loop until [condition] holds. These tests write actual
/// files, so "the drain has reached the processor" takes an unknown number of
/// turns rather than a countable handful of microtasks.
Future<void> _until(bool Function() condition, {int tries = 400}) async {
  for (int i = 0; i < tries && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  // The controller builds a real recorder and player; stubbing their channels is
  // what keeps this suite off any actual device.
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

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audivoa-deletion-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RecordingsController controllerFor(
    RecordingsRepository repository, {
    AudioRecorder? recorder,
    Processor? textProcessor,
  }) {
    final RecordingsController controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      recorder: recorder,
      processorRegistry: textProcessor == null
          ? null
          : ProcessorRegistry(<CaptureType, Processor>{
              CaptureType.text: textProcessor,
            }),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  List<File> backups(String reason) => root
      .listSync()
      .whereType<File>()
      .where((File file) => p.basename(file.path).contains('.$reason-'))
      .toList();

  group('discard while recording', () {
    test('deletes the partial file and indexes nothing', () async {
      final _GrantingRecorder recorder = _GrantingRecorder();
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
        recorder: recorder,
      );

      await controller.startRecording();
      final String path = recorder.path!;
      expect(File(path).existsSync(), isTrue);

      await controller.discardRecording();

      expect(controller.isRecording, isFalse);
      expect(controller.recordings, isEmpty);
      expect(File(path).existsSync(), isFalse);
      // Nothing was ever persisted, so the index was never even created — the
      // discard happens strictly before the capture is accepted.
      expect(File(p.join(root.path, 'recordings.json')).existsSync(), isFalse);
    });

    test('leaves no orphan for the recovery sweep to re-adopt', () async {
      final _GrantingRecorder recorder = _GrantingRecorder();
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
        recorder: recorder,
      );

      await controller.startRecording();
      await controller.discardRecording();
      await controller.recoverOrphans();

      expect(controller.recordings, isEmpty);
    });

    test('does nothing when no recording is running', () async {
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
        recorder: _GrantingRecorder(),
      );

      await controller.discardRecording();

      expect(controller.error, isNull);
      expect(controller.recordings, isEmpty);
    });
  });

  group('delete a persisted capture', () {
    test('removes the row, the source file and the poster', () async {
      final _TempRepository repository = _TempRepository(root);
      final RecordingsController controller = controllerFor(repository);

      await controller.addTextNote('keep me');
      await controller.addTextNote('drop me');
      await controller.waitForProcessing();
      expect(controller.recordings, hasLength(2));

      final Recording doomed = controller.recordings.firstWhere(
        (Recording item) => item.transcript == 'drop me',
      );
      // A poster is the only other file an item can own; stand one in so the
      // derived artifact is covered by the same call.
      final File poster = await repository.createSourceFile(
        doomed.id,
        'thumb.jpg',
      );
      await poster.writeAsBytes(<int>[0xFF, 0xD8]);

      await controller.deleteRecording(doomed.id);

      expect(controller.recordings, hasLength(1));
      expect(controller.recordings.single.transcript, 'keep me');
      expect(File(doomed.filePath).existsSync(), isFalse);
      expect(poster.existsSync(), isFalse);
      // The index on disk agrees, not just the in-memory list.
      final List<Recording> reloaded = await _TempRepository(root).loadAll();
      expect(reloaded.map((Recording item) => item.id), <String>[
        controller.recordings.single.id,
      ]);
    });

    test('an announced shrink writes no anomaly backup', () async {
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
      );

      await controller.addTextNote('one');
      await controller.addTextNote('two');
      await controller.waitForProcessing();

      await controller.deleteRecording(controller.recordings.first.id);

      // The guard exists to catch an index losing rows nobody asked to lose.
      // A deliberate delete announces itself, so it must stay silent — a copy
      // per deletion would bury the one that ever matters.
      expect(backups('shrank'), isEmpty);
    });

    test('a source file that will not delete leaves the row alone', () async {
      final RecordingsController controller = controllerFor(
        _UndeletableRepository(root),
      );

      await controller.addTextNote('stubborn');
      await controller.waitForProcessing();
      final Recording item = controller.recordings.single;

      await controller.deleteRecording(item.id);

      // Files first, index second: dropping the row here would leave a source
      // with no entry, which `recoverOrphans` would walk straight back in.
      expect(controller.recordings, hasLength(1));
      expect(File(item.filePath).existsSync(), isTrue);
      expect(controller.error, contains('Could not delete the source file'));
    });

    test('is refused while the index is unreadable', () async {
      final File index = File(p.join(root.path, 'recordings.json'));
      await index.writeAsString('{"not": "a list"}');
      final String before = await index.readAsString();

      final RecordingsController controller = controllerFor(
        _TempRepository(root),
      );
      await controller.initialize();
      expect(controller.isIndexUnreadable, isTrue);

      await controller.deleteRecording('anything');

      expect(controller.error, contains('Deletion is disabled'));
      expect(await index.readAsString(), before);
    });

    test('an unknown id is a no-op', () async {
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
      );

      await controller.addTextNote('only one');
      await controller.waitForProcessing();

      await controller.deleteRecording('not-a-real-id');

      expect(controller.recordings, hasLength(1));
      expect(controller.error, isNull);
    });
  });

  group('delete against the processing queue', () {
    test('a queued item is dropped before it ever runs', () async {
      final _GatedProcessor processor = _GatedProcessor();
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
        textProcessor: processor,
      );

      await controller.addTextNote('first');
      await controller.addTextNote('second');
      await _until(() => processor.gates.isNotEmpty);
      expect(processor.gates, hasLength(1)); // one running, one queued

      final Recording queued = controller.recordings.firstWhere(
        (Recording item) => item.status == RecordingStatus.pendingTranscription,
      );
      await controller.deleteRecording(queued.id);

      processor.gates.first.complete();
      await controller.waitForProcessing();

      expect(processor.processed, isNot(contains(queued.id)));
      expect(controller.recordings, hasLength(1));
    });

    test('deleting the running item does not derail the drain', () async {
      final _GatedProcessor processor = _GatedProcessor();
      final RecordingsController controller = controllerFor(
        _TempRepository(root),
        textProcessor: processor,
      );

      await controller.addTextNote('running');
      await _until(() => processor.gates.isNotEmpty);
      expect(processor.gates, hasLength(1));

      final Recording running = controller.recordings.single;
      await controller.deleteRecording(running.id);
      // Let the job it no longer belongs to finish writing into nothing.
      processor.gates.first.complete();
      await controller.waitForProcessing();

      expect(controller.recordings, isEmpty);
      expect(controller.isProcessing, isFalse);

      // The queue still works afterwards — the point of the exercise.
      await controller.addTextNote('after');
      await _until(() => processor.gates.length > 1);
      processor.gates.last.complete();
      await controller.waitForProcessing();

      expect(controller.recordings.single.status, RecordingStatus.completed);
    });
  });
}

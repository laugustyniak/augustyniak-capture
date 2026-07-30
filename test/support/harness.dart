import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audivoa_core/features/logs/data/log_store.dart';
import 'package:audivoa_core/features/recordings/data/media_picker.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_category.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/settings/data/settings_repository.dart';
import 'package:audivoa_core/features/settings/domain/app_settings.dart';
import 'package:audivoa_core/features/settings/presentation/settings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

/// Shared fakes and builders for the widget tests.
///
/// The tabs are plain widgets over their controllers, so a widget test needs
/// the same three fakes every time (repository, recorder, player) plus a host
/// that rebuilds on notification the way the real page shell does. Keeping them
/// here stops each new test file from re-deriving them.

/// Keeps the index in memory and puts source files in a temp dir — no
/// path_provider, no real `recordings.json`.
class FakeRecordingsRepository extends RecordingsRepository {
  FakeRecordingsRepository(this.directory, {this.seed = const <Recording>[]});

  final Directory directory;

  /// What `initialize()` will load. Seeding through the repository keeps the
  /// production controller free of a test-only mutation hook.
  final List<Recording> seed;
  List<Recording> saved = <Recording>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => List<Recording>.from(seed);

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class FakeSettingsRepository extends SettingsRepository {
  AppSettings? stored;

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async => stored = settings;
}

/// Only `onPlayerComplete` is touched at construction; everything else is a
/// no-op so the test never reaches a platform channel.
class FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class FakeRecorder implements AudioRecorder {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class FakePicker implements MediaPicker {
  FakePicker([this.result]);
  final PickedMedia? result;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => result;
}

/// A controller wired entirely to fakes, already `initialize()`d so [seed] is
/// loaded. `dispose` is registered with the test so a forgotten teardown cannot
/// leak a timer into the next case.
Future<RecordingsController> buildRecordingsController(
  Directory appDir, {
  List<Recording> seed = const <Recording>[],
  PickedMedia? picked,
  TranscriptionService service = const DisabledTranscriptionService(),
}) async {
  final RecordingsController controller = RecordingsController(
    repository: FakeRecordingsRepository(appDir, seed: seed),
    transcriptionService: service,
    mediaPicker: FakePicker(picked),
    recorder: FakeRecorder(),
    player: FakePlayer(),
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

SettingsController buildSettingsController({AppSettings? stored}) {
  final FakeSettingsRepository repository = FakeSettingsRepository()
    ..stored = stored;
  final SettingsController controller =
      SettingsController(repository: repository);
  addTearDown(controller.dispose);
  return controller;
}

LogStore buildLogStore({int capacity = 500}) {
  // No archive: memory-only, so nothing touches the filesystem.
  final LogStore store = LogStore(capacity: capacity);
  addTearDown(store.dispose);
  return store;
}

/// Hosts a tab the way `RecordingsPage` does: inside the app theme, and inside
/// an `AnimatedBuilder` over the controller so a mutation repaints. Without the
/// listener the stateless tabs would never rebuild and every assertion after an
/// interaction would read stale UI.
/// [build] is a callback, not a widget, on purpose: returning one cached
/// instance from the `AnimatedBuilder` makes Flutter short-circuit the rebuild
/// (the new widget is `identical` to the old one), so controller notifications
/// would never repaint and every post-interaction assertion would read stale UI.
Widget hostTab(Widget Function() build, {Listenable? listenable}) {
  final Widget body = listenable == null
      ? Builder(builder: (BuildContext context) => build())
      : AnimatedBuilder(
          animation: listenable,
          builder: (BuildContext context, Widget? _) => build(),
        );
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(body: body),
  );
}

/// Convenience matcher: a widget with this exact text is on screen.
Finder text(String value) => find.text(value);

Recording makeRecording({
  required String id,
  CaptureType type = CaptureType.audioRecording,
  RecordingStatus status = RecordingStatus.completed,
  String? transcript,
  String? title,
  CaptureCategory? category,
  String? summary,
  List<String> tags = const <String>[],
  String? error,
  int durationMs = 1500,
  int sizeBytes = 0,
  bool isProcessedByUser = false,
  String? filePath,
}) {
  return Recording(
    id: id,
    filePath: filePath ?? '/tmp/$id.m4a',
    createdAt: DateTime.utc(2026, 7, 27, 12),
    durationMs: durationMs,
    sizeBytes: sizeBytes,
    status: status,
    type: type,
    transcript: transcript,
    title: title,
    category: category,
    summary: summary,
    tags: tags,
    error: error,
    isProcessedByUser: isProcessedByUser,
  );
}

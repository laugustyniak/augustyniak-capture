import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/command/domain/command_client.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_sink.dart';
import 'package:augustyniak_capture/features/logs/data/log_store.dart';
import 'package:augustyniak_capture/features/gamification/presentation/gamification_controller.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/agent_handoff.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/media_opener.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/presentation/settings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:augustyniak_capture/features/transcription/domain/local_transcription_engine.dart';

/// Shared fakes and builders for the widget tests.
///
/// The tabs are plain widgets over their controllers, so a widget test needs
/// the same three fakes every time (repository, recorder, player) plus a host
/// that rebuilds on notification the way the real page shell does. Keeping them
/// here stops each new test file from re-deriving them.

/// Keeps the index in memory and puts source files in a temp dir — no
/// path_provider, no real `recordings.json`.
class FakeRecordingsRepository extends RecordingsRepository {
  FakeRecordingsRepository(
    this.directory, {
    this.seed = const <Recording>[],
    this.saveGate,
    this.saveError,
  });

  final Directory directory;

  /// What `initialize()` will load. Seeding through the repository keeps the
  /// production controller free of a test-only mutation hook.
  final List<Recording> seed;
  final Future<void>? saveGate;
  final Object? saveError;
  List<Recording> saved = <Recording>[];
  int saveCalls = 0;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => List<Recording>.from(seed);

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
    if (saveGate != null) await saveGate;
    if (saveError != null) throw saveError!;
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

/// Records what the card asked the platform to open instead of shelling out.
/// Keeps the "tapping play on a video hands the source to the system" test
/// free of `xdg-open`.
class FakeMediaOpener implements MediaOpener {
  final List<String> opened = <String>[];

  @override
  Future<void> open(String path) async => opened.add(path);
}

/// A controller wired entirely to fakes, already `initialize()`d so [seed] is
/// loaded. `dispose` is registered with the test so a forgotten teardown cannot
/// leak a timer into the next case.
Future<RecordingsController> buildRecordingsController(
  Directory appDir, {
  List<Recording> seed = const <Recording>[],
  PickedMedia? picked,
  TranscriptionService service = const DisabledTranscriptionService(),
  MediaOpener mediaOpener = const NoopMediaOpener(),
  CaptureRouter captureRouter = const DisabledCaptureRouter(),
  AgentHandoff agentHandoff = const DisabledAgentHandoff(),
  FakeRecordingsRepository? repository,
  UsageSink usageSink = const NoopUsageSink(),
  ClosureLog closureLog = const NoopClosureLog(),
  Project? Function(String projectId)? projectById,
  GamificationController? gamificationController,
  CommandClient commandClient = const DisabledCommandClient(),
  String? Function()? commandBaseUrl,
}) async {
  final RecordingsController controller = RecordingsController(
    repository: repository ?? FakeRecordingsRepository(appDir, seed: seed),
    transcriptionService: service,
    mediaPicker: FakePicker(picked),
    mediaOpener: mediaOpener,
    captureRouter: captureRouter,
    agentHandoff: agentHandoff,
    recorder: FakeRecorder(),
    player: FakePlayer(),
    usageSink: usageSink,
    closureLog: closureLog,
    projectById: projectById,
    gamificationController: gamificationController,
    commandClient: commandClient,
    commandBaseUrl: commandBaseUrl,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

SettingsController buildSettingsController({
  AppSettings? stored,
  LocalTranscriptionEngine localEngine = const UnavailableLocalEngine(),
}) {
  final FakeSettingsRepository repository = FakeSettingsRepository()
    ..stored = stored;
  final SettingsController controller = SettingsController(
    repository: repository,
    localEngine: localEngine,
  );
  addTearDown(controller.dispose);
  return controller;
}

class _MemoryLogArchive implements LogArchive {
  const _MemoryLogArchive();
  @override
  Future<List<LogEvent>> load() async => <LogEvent>[];
  @override
  Future<void> save(List<LogEvent> events) async {}
}

LogStore buildLogStore({int capacity = 500}) {
  // Memory-only archive so nothing touches the filesystem or SQLite database in harness tests.
  final LogStore store = LogStore(
    archive: const _MemoryLogArchive(),
    capacity: capacity,
  );
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
  String? projectId,
  String? error,
  int durationMs = 1500,
  int sizeBytes = 0,
  bool isProcessedByUser = false,
  DateTime? processedAt,
  List<RouteRecord> routes = const <RouteRecord>[],
  String? filePath,
  String? thumbPath,
}) {
  return Recording(
    id: id,
    filePath: filePath ?? '/tmp/$id.m4a',
    createdAt: DateTime.utc(2026, 7, 27, 12),
    processedAt: processedAt,
    routes: routes,
    durationMs: durationMs,
    sizeBytes: sizeBytes,
    status: status,
    type: type,
    transcript: transcript,
    thumbPath: thumbPath,
    title: title,
    category: category,
    summary: summary,
    tags: tags,
    projectId: projectId,
    error: error,
    isProcessedByUser: isProcessedByUser,
  );
}

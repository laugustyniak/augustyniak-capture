import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fake_sync_transport.dart';
import 'media_sync_test.dart' show FakeMediaStore;

class _FakeAuthGateway implements AuthGateway {
  @override
  AuthIdentity? get currentIdentity =>
      const AuthIdentity(id: 'u1', email: 'u1@example.com');

  @override
  Stream<AuthIdentity?> get identityChanges =>
      const Stream<AuthIdentity?>.empty();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {}
}

/// The Storage slot end to end through `RecordingsController.syncCloud()`:
/// the re-root step, the download and the hand-off to processing.
void main() {
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

  const List<int> audio = <int>[1, 2, 3, 4];
  late Directory dir;
  late FakeMediaStore store;
  String? requestedOwner;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-media-slot-',
    );
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    store = FakeMediaStore();
    requestedOwner = null;
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> seedIndex(Recording r) => File(
    '${dir.path}/recordings.json',
  ).writeAsString(jsonEncode(<Object?>[r.toJson()]));

  /// A row an earlier Supabase pull left behind: bare file name, no source.
  Recording pulledRow(RecordingStatus status) => Recording(
    id: 'r1',
    filePath: 'r1.m4a',
    createdAt: DateTime.utc(2026, 9, 23, 8),
    durationMs: 1200,
    sizeBytes: audio.length,
    contentHash: sha256.convert(audio).toString(),
    status: status,
    type: CaptureType.audioRecording,
    transcript: status == RecordingStatus.completed ? 'hello' : null,
  );

  RecordingsController controller() {
    final RecordingsController c = RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => dir),
      transcriptionService: const DisabledTranscriptionService(),
      syncTransportResolver: FakeSyncTransport.new,
      authGateway: _FakeAuthGateway(),
      projectsRepository: ProjectsRepository(
        directoryProvider: () async => dir,
      ),
      clipboardRepository: LocalJsonClipboardRepository(
        storageDirectoryProvider: () async => dir,
      ),
      syncDeviceId: () async => 'device-1',
      applySyncedProjects: (_) async {},
      applySyncedProjectDelete: (_) async {},
      mediaStoreResolver: (String ownerId) {
        requestedOwner = ownerId;
        return store;
      },
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a pulled row is re-rooted, downloaded and then processed', () async {
    await seedIndex(pulledRow(RecordingStatus.pendingTranscription));
    store.objects['captures/r1/r1.m4a'] = audio;
    final RecordingsController c = controller();
    await c.initialize();
    await c.resumeInterruptedProcessing();
    expect(
      c.recordings.single.status,
      RecordingStatus.pendingTranscription,
      reason: 'no source yet, so processing is refused',
    );

    final CloudSyncReport report = await c.syncCloud();
    await c.waitForProcessing();

    expect(requestedOwner, 'u1');
    expect(report.media?.downloaded, 1);
    final Recording r = c.recordings.single;
    expect(r.filePath, p.join(dir.path, 'r1.m4a'));
    expect(await File(r.filePath).readAsBytes(), audio);
    expect(
      r.status,
      isNot(RecordingStatus.pendingTranscription),
      reason: 'the downloaded source reached the processor',
    );
  });

  test(
    'a completed pulled row gains its source and keeps its status',
    () async {
      await seedIndex(pulledRow(RecordingStatus.completed));
      store.objects['captures/r1/r1.m4a'] = audio;
      final RecordingsController c = controller();
      await c.initialize();

      final CloudSyncReport report = await c.syncCloud();

      expect(report.media?.downloaded, 1);
      expect(report.message, contains('Storage: 1 downloaded'));
      final Recording r = c.recordings.single;
      expect(r.status, RecordingStatus.completed);
      expect(r.transcript, 'hello');
      expect(File(r.filePath).existsSync(), isTrue);
    },
  );

  test('a mismatched download leaves no source and no status change', () async {
    await seedIndex(pulledRow(RecordingStatus.pendingTranscription));
    store.objects['captures/r1/r1.m4a'] = <int>[9, 9];
    final RecordingsController c = controller();
    await c.initialize();

    final CloudSyncReport report = await c.syncCloud();

    expect(report.media?.rejected, 1);
    expect(report.success, isFalse);
    final Recording r = c.recordings.single;
    expect(File(r.filePath).existsSync(), isFalse);
    expect(r.status, RecordingStatus.pendingTranscription);
  });

  test('a row is not processed until every fragment is here', () async {
    final String hash = sha256.convert(audio).toString();
    final DateTime at = DateTime.utc(2026, 9, 23, 8);
    await seedIndex(
      Recording(
        id: 'r1',
        filePath: 'r1.m4a',
        createdAt: at,
        durationMs: 1200,
        contentHash: hash,
        status: RecordingStatus.saved,
        type: CaptureType.audioRecording,
        segments: <CaptureSegment>[
          for (final (int i, String name) in <(int, String)>[
            (0, 'r1.m4a'),
            (1, 'r1-1.m4a'),
          ])
            CaptureSegment(
              index: i,
              filePath: name,
              type: CaptureType.audioRecording,
              createdAt: at,
              contentHash: hash,
            ),
        ],
      ),
    );
    store.objects['captures/r1/r1.m4a'] = audio;
    final RecordingsController c = controller();
    await c.initialize();

    final CloudSyncReport report = await c.syncCloud();
    await c.waitForProcessing();

    expect(report.media?.downloaded, 1);
    expect(report.media?.waiting, 1);
    expect(
      c.recordings.single.status,
      RecordingStatus.saved,
      reason: 'fragment 1 is still waiting, so processing is refused',
    );
  });

  test('a local capture is uploaded under its recording id', () async {
    final String source = p.join(dir.path, 'r1.m4a');
    await File(source).writeAsBytes(audio);
    await seedIndex(
      Recording(
        id: 'r1',
        filePath: source,
        createdAt: DateTime.utc(2026, 9, 23, 8),
        durationMs: 1200,
        contentHash: sha256.convert(audio).toString(),
        status: RecordingStatus.completed,
        type: CaptureType.audioRecording,
      ),
    );
    final RecordingsController c = controller();
    await c.initialize();

    final CloudSyncReport report = await c.syncCloud();

    expect(report.media?.uploaded, 1);
    expect(store.objects['captures/r1/r1.m4a'], audio);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_sync_transport.dart';

class _FakeAuthGateway implements AuthGateway {
  @override
  AuthIdentity? get currentIdentity =>
      const AuthIdentity(id: 'u1', email: 'u1@example.com');

  @override
  Stream<AuthIdentity?> get identityChanges => const Stream<AuthIdentity?>.empty();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {}
}

/// Counts `loadAll()` calls so the test can prove a Supabase-only run does
/// not read the index back from disk — see `docs/architecture/sync.md`'s
/// lost-write hazard `applySyncedRecordings` closes.
class _CountingRepository extends RecordingsRepository {
  _CountingRepository(Directory dir) : super(directoryProvider: () async => dir);

  int loadAllCalls = 0;

  @override
  Future<List<Recording>> loadAll() async {
    loadAllCalls++;
    return super.loadAll();
  }
}

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

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'augustyniak-capture-supabase-only-no-reload-',
    );
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    await File('${dir.path}/recordings.json').writeAsString('[]');
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'a Supabase-only run does not reload from storage — finding 6',
    () async {
      final _CountingRepository repository = _CountingRepository(dir);
      final FakeSyncTransport transport = FakeSyncTransport();
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
        // Turso/R2 are left unconfigured (no dart-defines, no SyncDefaults),
        // so only the Supabase slot is wired here.
        syncTransportResolver: () => transport,
        authGateway: _FakeAuthGateway(),
        projectsRepository: ProjectsRepository(directoryProvider: () async => dir),
        clipboardRepository: LocalJsonClipboardRepository(
          storageDirectoryProvider: () async => dir,
        ),
        syncDeviceId: () async => 'device-1',
        applySyncedProjects: (_) async {},
        applySyncedProjectDelete: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      final int loadAllCallsAfterInit = repository.loadAllCalls;

      final CloudSyncReport report = await controller.syncCloud();

      expect(report.supabase, isNotNull);
      expect(
        repository.loadAllCalls,
        loadAllCallsAfterInit,
        reason: 'the Supabase pull already merged in place through '
            'applySyncedRecordings — a reload would replace _recordings '
            'with whatever is on disk right now, reverting a writer '
            'queued behind _saveInFlight',
      );
    },
  );
}

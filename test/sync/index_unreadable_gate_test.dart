import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
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
      'augustyniak-capture-index-unreadable-gate-',
    );
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    // Unreadable on purpose — `RecordingsController.initialize()` sets
    // `isIndexUnreadable` from this.
    await File('${dir.path}/recordings.json').writeAsString('not json at all');
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'an unreadable index keeps Supabase out of syncCloud() — I1',
    () async {
      final FakeSyncTransport transport = FakeSyncTransport();
      // Bookkeeping alone would make an empty push read as "everything
      // deleted" if this gate did not hold — see the doc comment on
      // `hasSupabase`.
      final RecordingsController controller = RecordingsController(
        repository: RecordingsRepository(directoryProvider: () async => dir),
        transcriptionService: const DisabledTranscriptionService(),
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
      expect(controller.isIndexUnreadable, isTrue);

      final CloudSyncReport report = await controller.syncCloud();

      expect(
        report.supabase,
        isNull,
        reason: 'the slot must not have run at all',
      );
      expect(
        transport.pushes,
        isEmpty,
        reason: 'nothing was pushed — the engine never ran',
      );
    },
  );

  test(
    'a readable index still runs the Supabase slot — the gate is specific',
    () async {
      await File('${dir.path}/recordings.json').writeAsString('[]');
      final FakeSyncTransport transport = FakeSyncTransport();
      final RecordingsController controller = RecordingsController(
        repository: RecordingsRepository(directoryProvider: () async => dir),
        transcriptionService: const DisabledTranscriptionService(),
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
      expect(controller.isIndexUnreadable, isFalse);

      final CloudSyncReport report = await controller.syncCloud();

      expect(report.supabase, isNotNull);
    },
  );
}

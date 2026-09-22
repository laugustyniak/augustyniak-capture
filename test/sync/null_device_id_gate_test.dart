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
      'augustyniak-capture-null-device-id-gate-',
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
    'a null device id (settings never loaded) skips the Supabase slot '
    'without throwing — finding 3',
    () async {
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
        // Mirrors `SettingsController.ensureSyncDeviceId()` returning null
        // because `initialize()` never actually loaded settings.
        syncDeviceId: () async => null,
        applySyncedProjects: (_) async {},
        applySyncedProjectDelete: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.isIndexUnreadable, isFalse);

      final CloudSyncReport report = await controller.syncCloud();

      expect(report.supabase, isNotNull);
      expect(report.supabase!.success, isFalse);
      expect(
        report.supabase!.failureReason,
        'sync skipped: settings unavailable',
      );
      expect(
        transport.pushes,
        isEmpty,
        reason: 'the engine must never run without a device id',
      );
    },
  );
}

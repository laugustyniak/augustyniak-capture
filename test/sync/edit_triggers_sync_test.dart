import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_sync_transport.dart';

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({required this.signedIn});

  final bool signedIn;

  @override
  AuthIdentity? get currentIdentity =>
      signedIn ? const AuthIdentity(id: 'u1', email: 'u1@example.com') : null;

  @override
  Stream<AuthIdentity?> get identityChanges =>
      const Stream<AuthIdentity?>.empty();

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
      'augustyniak-capture-edit-triggers-sync-',
    );
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    await File('${dir.path}/recordings.json').writeAsString('[]');
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  RecordingsController build(
    FakeSyncTransport transport, {
    required bool signedIn,
  }) {
    return RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => dir),
      transcriptionService: const DisabledTranscriptionService(),
      syncTransportResolver: () => transport,
      authGateway: _FakeAuthGateway(signedIn: signedIn),
      projectsRepository: ProjectsRepository(
        directoryProvider: () async => dir,
      ),
      clipboardRepository: LocalJsonClipboardRepository(
        storageDirectoryProvider: () async => dir,
      ),
      syncDeviceId: () async => 'device-1',
      applySyncedProjects: (_) async {},
      applySyncedProjectDelete: (_) async {},
      editSyncDelay: const Duration(milliseconds: 20),
    );
  }

  int recordingPushes(FakeSyncTransport transport) =>
      transport.pushes.where((p) => p.$1 == SyncTable.recordings).length;

  test('a user edit while signed in pushes once after the debounce', () async {
    final FakeSyncTransport transport = FakeSyncTransport();
    final RecordingsController controller = build(transport, signedIn: true);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.addTextNote('first body');
    final String id = controller.recordings.single.id;

    // Two edits inside one debounce window coalesce into a single run.
    await controller.setTitle(id, 'Edited title');
    await controller.setSummary(id, 'Edited summary');
    expect(controller.lastCloudSyncReport, isNull);

    for (int i = 0; i < 200 && controller.lastCloudSyncReport == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.lastCloudSyncReport, isNotNull);
    expect(recordingPushes(transport), 1);
    final Map<String, Object?> row =
        transport.tables[SyncTable.recordings]!.values.single;
    expect(row.toString(), contains('Edited title'));
    expect(row.toString(), contains('Edited summary'));
  });

  test('a user edit while signed out never starts a sync', () async {
    final FakeSyncTransport transport = FakeSyncTransport();
    final RecordingsController controller = build(transport, signedIn: false);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.addTextNote('first body');
    final String id = controller.recordings.single.id;

    await controller.setTitle(id, 'Edited title');
    // A negative cannot be polled for; ten debounce windows is the bound.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.lastCloudSyncReport, isNull);
    expect(transport.pushes, isEmpty);
  });
}

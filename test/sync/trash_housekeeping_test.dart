import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
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

class _PruneCountingRepository extends RecordingsRepository {
  _PruneCountingRepository(Directory dir)
    : super(directoryProvider: () async => dir);

  int prunes = 0;

  @override
  Future<int> pruneTrash({DateTime? now}) {
    prunes++;
    return super.pruneTrash(now: now);
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
      'augustyniak-capture-trash-housekeeping-',
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
    _PruneCountingRepository repository, {
    required bool signedIn,
  }) {
    return RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      syncTransportResolver: (_, _) => FakeSyncTransport(),
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
    );
  }

  test('a run that reached Supabase prunes the trash', () async {
    final _PruneCountingRepository repository = _PruneCountingRepository(dir);
    final RecordingsController controller = build(repository, signedIn: true);
    addTearDown(controller.dispose);
    await controller.initialize();

    final report = await controller.syncCloud();

    expect(report.supabase, isNotNull);
    expect(repository.prunes, 1);
  });

  test('a run that never reached Supabase leaves the trash alone', () async {
    final _PruneCountingRepository repository = _PruneCountingRepository(dir);
    final RecordingsController controller = build(repository, signedIn: false);
    addTearDown(controller.dispose);
    await controller.initialize();

    final report = await controller.syncCloud();

    expect(report.supabase, isNull);
    expect(repository.prunes, 0);
  });
}

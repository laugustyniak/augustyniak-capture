import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_binding.dart';
import 'package:augustyniak_capture/features/sync/presentation/sync_binding_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_sync_binding_store.dart';
import 'fake_sync_transport.dart';
import 'media_sync_test.dart' show FakeMediaStore;

class _MutableAuthGateway implements AuthGateway {
  _MutableAuthGateway(this.currentIdentity);

  @override
  AuthIdentity? currentIdentity;

  @override
  Stream<AuthIdentity?> get identityChanges =>
      const Stream<AuthIdentity?>.empty();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {}
}

/// #206 through `RecordingsController.syncCloud()`: a run the binding gate
/// pauses resolves neither the transport nor the media store, so no push,
/// pull or Storage call can happen at all.
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

  const AuthIdentity a = AuthIdentity(id: 'owner-a', email: 'a@example.com');
  const AuthIdentity b = AuthIdentity(id: 'owner-b', email: 'b@example.com');

  late Directory dir;
  late FakeSyncBindingStore bindingStore;
  late SyncBindingController binding;
  late FakeSyncTransport transport;
  late FakeMediaStore media;
  late int transportResolves;
  late int mediaResolves;
  late int gateCalls;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('augustyniak-capture-binding-');
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    await File('${dir.path}/recordings.json').writeAsString('[]');
    bindingStore = FakeSyncBindingStore();
    binding = SyncBindingController(store: () async => bindingStore);
    transport = FakeSyncTransport();
    media = FakeMediaStore();
    transportResolves = 0;
    mediaResolves = 0;
    gateCalls = 0;
  });

  tearDown(() async {
    binding.dispose();
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Polled, never slept — see `docs/architecture/testing.md`.
  Future<void> settled(RecordingsController controller) async {
    for (int i = 0; i < 500 && controller.isProcessing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.isProcessing, isFalse);
  }

  RecordingsController build(_MutableAuthGateway gateway) {
    final RecordingsController c = RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => dir),
      transcriptionService: const DisabledTranscriptionService(),
      syncTransportResolver: (_, _) {
        transportResolves += 1;
        return transport;
      },
      authGateway: gateway,
      projectsRepository: ProjectsRepository(
        directoryProvider: () async => dir,
      ),
      clipboardRepository: LocalJsonClipboardRepository(
        storageDirectoryProvider: () async => dir,
      ),
      syncDeviceId: () async => 'device-1',
      applySyncedProjects: (_) async {},
      applySyncedProjectDelete: (_) async {},
      mediaStoreResolver: (_) {
        mediaResolves += 1;
        return media;
      },
      syncBindingGate: (AuthIdentity identity, {required bool libraryIsEmpty}) {
        gateCalls += 1;
        return binding.gate(identity, libraryIsEmpty: libraryIsEmpty);
      },
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<RecordingsController> withOneNote(_MutableAuthGateway gateway) async {
    final RecordingsController c = build(gateway);
    await c.initialize();
    await c.addTextNote('body');
    await settled(c);
    return c;
  }

  test(
    'an unbound device with local data makes no push, pull or media call until confirmed',
    () async {
      final RecordingsController c = await withOneNote(_MutableAuthGateway(a));

      final CloudSyncReport report = await c.syncCloud();

      expect(transportResolves, 0);
      expect(mediaResolves, 0);
      expect(transport.pushes, isEmpty);
      expect(media.objects, isEmpty);
      expect(report.media, isNull);
      expect(report.supabase?.failureReason, contains('paused'));
      expect(bindingStore.owner, isA<SyncOwnerAbsent>());
      expect(c.recordings, hasLength(1), reason: 'local data untouched');

      expect(await binding.confirmUpload(), isTrue);
      final CloudSyncReport after = await c.syncCloud();
      expect(transportResolves, 1);
      expect(mediaResolves, 1);
      expect(transport.pushes, isNotEmpty);
      expect(after.supabase?.success, isTrue);
    },
  );

  test('an empty library binds silently and syncs', () async {
    final RecordingsController c = build(_MutableAuthGateway(a));
    await c.initialize();

    await c.syncCloud();

    expect(transportResolves, 1);
    expect((bindingStore.owner as SyncOwnerBound).id, 'owner-a');
  });

  test(
    'a mismatched account makes no push, pull or media call and the report names the bound account',
    () async {
      bindingStore.owner = const SyncOwnerBound(
        id: 'owner-a',
        email: 'a@example.com',
      );
      final RecordingsController c = await withOneNote(_MutableAuthGateway(b));

      final CloudSyncReport report = await c.syncCloud();

      expect(transportResolves, 0);
      expect(mediaResolves, 0);
      expect(transport.pushes, isEmpty);
      expect(report.message, contains('a@example.com'));
    },
  );

  test(
    'an unreadable binding is treated as a mismatch, even with an empty library',
    () async {
      bindingStore.owner = const SyncOwnerUnreadable();
      final RecordingsController c = build(_MutableAuthGateway(a));
      await c.initialize();

      final CloudSyncReport report = await c.syncCloud();

      expect(transportResolves, 0);
      expect(mediaResolves, 0);
      expect(report.supabase?.success, isFalse);
      expect(bindingStore.binds, 0);
    },
  );

  test('signed out, the gate is never asked and nothing changes', () async {
    final RecordingsController c = await withOneNote(_MutableAuthGateway(null));

    final CloudSyncReport report = await c.syncCloud();

    expect(gateCalls, 0);
    expect(transportResolves, 0);
    expect(report.supabase, isNull);
    expect(report.message, 'Cloud sync is not configured.');
    expect(bindingStore.binds, 0);
  });

  test(
    'a gate that throws pauses the run instead of failing syncCloud',
    () async {
      final RecordingsController c = await withOneNote(_MutableAuthGateway(a));
      bindingStore.readThrows = true;

      final CloudSyncReport report = await c.syncCloud();

      expect(transportResolves, 0);
      expect(mediaResolves, 0);
      expect(report.supabase?.success, isFalse);
    },
  );
}

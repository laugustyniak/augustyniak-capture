import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/cloud_sync_coordinator.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/clipboard/data/clipboard_repository.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/projects/data/projects_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_sync_transport.dart';

/// #297: the decorators existed and nothing built them. This drives the
/// controller's Supabase slot through the same resolver shape `app.dart`
/// hands it — `E2eeService.wrapTransport` over a plain transport — and reads
/// what reached the wire.
class _FakeAuthGateway implements AuthGateway {
  @override
  AuthIdentity? get currentIdentity =>
      const AuthIdentity(id: 'owner-1', email: 'u1@example.com');

  @override
  Stream<AuthIdentity?> get identityChanges =>
      const Stream<AuthIdentity?>.empty();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {}
}

class _InMemorySecureStore implements SecureValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _RecordingLogSink implements LogSink {
  final List<String> lines = <String>[];

  @override
  void log(String message, {LogLevel level = LogLevel.info, String? recordingId}) {
    lines.add(message);
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
    dir = await Directory.systemTemp.createTemp('augustyniak-capture-e2ee-wiring-');
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: sqlite3.openInMemory());
    await File('${dir.path}/recordings.json').writeAsString('[]');
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// `addTextNote` persists, then drains processing in the background; the
  /// drain writes the index, so it has to finish before tearDown removes
  /// the directory. Polled, never slept — see `docs/architecture/testing.md`.
  Future<void> settled(RecordingsController controller) async {
    for (int i = 0; i < 500 && controller.isProcessing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.isProcessing, isFalse);
  }

  Future<E2eeService> service({required bool unlocked}) async {
    final E2eeService e2ee = E2eeService(
      secureStore: _InMemorySecureStore(),
      kdf: E2eeKeyDerivation(iterations: 1000),
    );
    await e2ee.followIdentity('owner-1');
    if (unlocked) {
      await e2ee.setupPassphrase(userId: 'owner-1', passphrase: 'pass');
    }
    return e2ee;
  }

  /// Mirrors `app.dart`: a fresh plain transport per call, wrapped by the
  /// service. Records what the controller handed the resolver.
  RecordingsController build(
    E2eeService e2ee,
    FakeSyncTransport inner, {
    required LogSink logSink,
    required List<(String, LogSink, SyncTransport)> calls,
  }) {
    return RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => dir),
      transcriptionService: const DisabledTranscriptionService(),
      logSink: logSink,
      syncTransportResolver: (String ownerId, LogSink log) {
        final SyncTransport transport =
            e2ee.wrapTransport(inner, ownerId: ownerId, log: log);
        calls.add((ownerId, log, transport));
        return transport;
      },
      authGateway: _FakeAuthGateway(),
      projectsRepository: ProjectsRepository(directoryProvider: () async => dir),
      clipboardRepository: LocalJsonClipboardRepository(
        storageDirectoryProvider: () async => dir,
      ),
      syncDeviceId: () async => 'device-1',
      applySyncedProjects: (_) async {},
      applySyncedProjectDelete: (_) async {},
    );
  }

  test('with a key, the engine runs over EncryptedSyncTransport and no content reaches the wire', () async {
    final E2eeService e2ee = await service(unlocked: true);
    final FakeSyncTransport inner = FakeSyncTransport();
    final _RecordingLogSink log = _RecordingLogSink();
    final List<(String, LogSink, SyncTransport)> calls = [];
    final RecordingsController controller =
        build(e2ee, inner, logSink: log, calls: calls);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.addTextNote('body');
    await settled(controller);
    await controller.setTitle(controller.recordings.single.id, 'Secret title');

    await controller.syncCloud();

    expect(calls, hasLength(1));
    final (String ownerId, LogSink handedLog, SyncTransport transport) = calls.single;
    expect(ownerId, 'owner-1', reason: 'the envelope is bound to the signed-in owner');
    expect(identical(handedLog, log), isTrue,
        reason: 'a row that fails to open must be reported where the Logs tab reads');
    expect(transport, isA<EncryptedSyncTransport>());

    final Map<String, Object?> row =
        inner.tables[SyncTable.recordings]!.values.single;
    expect(row['title'], isNull);
    expect(row['encrypted_payload'], startsWith(E2eeCipher.sealedPrefix));
    for (final (SyncTable table, List<Map<String, Object?>> rows) in inner.pushes) {
      for (final Map<String, Object?> pushed in rows) {
        expect(pushed.toString(), isNot(contains('Secret title')),
            reason: '$table row leaked the title');
      }
    }
  });

  test('without a key, the plain transport is used and rows leave in plaintext', () async {
    // The honest fallback #297 allows: never silently. The Queue's sync
    // status says NOT ENCRYPTED for this run (see queue_tab_test).
    final E2eeService e2ee = await service(unlocked: false);
    final FakeSyncTransport inner = FakeSyncTransport();
    final _RecordingLogSink log = _RecordingLogSink();
    final List<(String, LogSink, SyncTransport)> calls = [];
    final RecordingsController controller =
        build(e2ee, inner, logSink: log, calls: calls);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.addTextNote('body');
    await settled(controller);
    await controller.setTitle(controller.recordings.single.id, 'Plain title');

    await controller.syncCloud();

    // Plain, not sealed: the guard in front of the plain transport only
    // re-checks the server row, and the rows reach the fake unchanged.
    expect(calls.single.$3, isNot(isA<EncryptedSyncTransport>()));
    final Map<String, Object?> row=
        inner.tables[SyncTable.recordings]!.values.single;
    expect(row['title'], 'Plain title');
    expect(row['encrypted_payload'], isNull);
    // The launch and edit-debounce runs show no panel; the Logs tab line is
    // what those leave behind.
    expect(log.lines, contains(contains('rows leave in plaintext')));
  });

  test('a resolver that refuses the run yields a failed slot, not a plaintext push', () async {
    // The service follows A; the gateway already says owner-1. The wrapper
    // throws, the controller reports it, nothing reaches the inner transport.
    final E2eeService e2ee = E2eeService(
      secureStore: _InMemorySecureStore(),
      kdf: E2eeKeyDerivation(iterations: 1000),
    );
    await e2ee.followIdentity('someone-else');
    final FakeSyncTransport inner = FakeSyncTransport();
    final List<(String, LogSink, SyncTransport)> calls = [];
    final RecordingsController controller =
        build(e2ee, inner, logSink: const NoopLogSink(), calls: calls);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.addTextNote('body');
    await settled(controller);

    final CloudSyncReport report = await controller.syncCloud();

    expect(report.supabase?.success, isFalse);
    expect(report.supabase?.failureReason, contains('sync skipped'));
    expect(inner.pushes, isEmpty);
    expect(calls, isEmpty);
  });

  test('the app shell builds the key holder and wraps both resolvers through it', () {
    // The shell needs a live SupabaseClient to run, so the wiring itself is
    // pinned at the source: remove either wrap and this fails before a
    // release pushes plaintext again.
    final String shell = File('lib/app/app.dart').readAsStringSync();
    expect(shell, contains('E2eeService('));
    expect(shell, contains('SupabaseE2eeSettingsStore('));
    expect(shell, contains('.wrapTransport('));
    expect(shell, contains('.wrapMediaStore('));
    expect(shell, contains('.followIdentity('));
    expect(shell, contains('e2eeService: _e2ee'));
    expect(
      shell.indexOf('SupabaseSyncTransport(widget.supabaseClient!)'),
      greaterThan(shell.indexOf('.wrapTransport(')),
      reason: 'the plain transport is only ever built as the wrap argument',
    );
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_media_store.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_settings_store.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';

import 'fake_e2ee_settings_store.dart';
import 'fake_sync_transport.dart';

class _FakeMediaStore implements MediaObjectStore {
  @override
  Future<bool> exists(String key) async => false;

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {}

  @override
  Stream<List<int>> download(String key, {required int maxBytes}) => const Stream<List<int>>.empty();
}

/// Answers `read` only once [gate] completes, to order a slow keyring read
/// after a later identity change; `write` likewise waits on [writeGate]
/// when one is set.
class _GatedSecureStore implements SecureValueStore {
  _GatedSecureStore(this.inner, this.gate);

  final SecureValueStore inner;
  Completer<String?> gate;
  Completer<void>? writeGate;
  int writes = 0;

  @override
  Future<bool> containsKey(String key) => inner.containsKey(key);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<String?> read(String key) => gate.future;

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    if (writeGate case final Completer<void> gate) await gate.future;
    await inner.write(key, value);
  }
}

/// Refuses every write: a keyring that is locked or unavailable.
class _ReadOnlySecureStore extends InMemorySecureStore {
  @override
  Future<void> write(String key, String value) async {
    throw StateError('keyring unavailable');
  }
}

class InMemorySecureStore implements SecureValueStore {
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

void main() {
  late InMemorySecureStore secureStore;
  late E2eeService service;

  setUp(() {
    secureStore = InMemorySecureStore();
    service = E2eeService(
      secureStore: secureStore,
      kdf: E2eeKeyDerivation(iterations: 1000),
    );
  });

  test('setupNewPassphrase initializes salt, check hash, iterations and active cipher', () async {
    const String userId = 'usr-123';
    final E2eePublicParams params = await service.setupPassphrase(
      userId: userId,
      passphrase: 'correct-horse-battery',
    );

    expect(params.saltBase64, isNotEmpty);
    expect(params.keyCheckHash, startsWith(E2eeKeyDerivation.keyCheckPrefix));
    expect(params.iterations, 1000, reason: 'the count the key was derived with travels with the salt');
    expect(service.isUnlocked, isTrue);
    expect(service.cipher, isNotNull);

    // Verify MEK is persisted securely in keyring
    final String? storedMek = await secureStore.read('ai.augustyniak.capture.e2ee.mek.$userId');
    expect(storedMek, isNotNull);
  });

  test('unlockWithPassphrase succeeds with correct passphrase and rejects wrong one', () async {
    const String userId = 'usr-456';
    final E2eePublicParams setup = await service.setupPassphrase(
      userId: userId,
      passphrase: 'my-strong-password',
    );

    // Clear session memory
    service.lock();
    expect(service.isUnlocked, isFalse);
    expect(service.cipher, isNull);

    // Fail with wrong passphrase
    expect(
      () => service.unlockWithPassphrase(
        userId: userId,
        passphrase: 'wrong-guess-password',
        saltBase64: setup.saltBase64,
        expectedCheckHash: setup.keyCheckHash,
        iterations: setup.iterations,
      ),
      throwsA(isA<InvalidE2eePassphraseException>()),
    );
    expect(service.isUnlocked, isFalse);

    // Succeed with correct passphrase
    final bool unlocked = await service.unlockWithPassphrase(
      userId: userId,
      passphrase: 'my-strong-password',
      saltBase64: setup.saltBase64,
      expectedCheckHash: setup.keyCheckHash,
      iterations: setup.iterations,
    );

    expect(unlocked, isTrue);
    expect(service.isUnlocked, isTrue);
    expect(service.cipher, isNotNull);
  });

  test('unlock derives with the stored iteration count, not this build\'s default', () async {
    // A key set up at 1000 iterations by an older build must still open on
    // a build whose default is higher — and the wrong count must read as a
    // wrong passphrase, never as a different key that silently decrypts
    // nothing.
    const String userId = 'usr-iter';
    final E2eePublicParams setup = await service.setupPassphrase(
      userId: userId,
      passphrase: 'persisted-secret',
    );
    final E2eeService newerBuild = E2eeService(
      secureStore: InMemorySecureStore(),
      kdf: E2eeKeyDerivation(iterations: 2000),
    );

    expect(
      () => newerBuild.unlockWithPassphrase(
        userId: userId,
        passphrase: 'persisted-secret',
        saltBase64: setup.saltBase64,
        expectedCheckHash: setup.keyCheckHash,
        iterations: 2000,
      ),
      throwsA(isA<InvalidE2eePassphraseException>()),
    );
    expect(
      await newerBuild.unlockWithPassphrase(
        userId: userId,
        passphrase: 'persisted-secret',
        saltBase64: setup.saltBase64,
        expectedCheckHash: setup.keyCheckHash,
        iterations: setup.iterations,
      ),
      isTrue,
    );
  });

  test('a server row with an out-of-range iteration count is refused before deriving', () async {
    final E2eePublicParams setup = await service.setupPassphrase(
      userId: 'usr-hostile',
      passphrase: 'persisted-secret',
    );
    expect(
      () => service.unlockWithPassphrase(
        userId: 'usr-hostile',
        passphrase: 'persisted-secret',
        saltBase64: setup.saltBase64,
        expectedCheckHash: setup.keyCheckHash,
        iterations: 2147483647,
      ),
      throwsArgumentError,
    );
  });

  test('a pre-kc1 check tag is reported as a legacy row, not a wrong passphrase', () async {
    final E2eePublicParams setup = await service.setupPassphrase(
      userId: 'usr-legacy',
      passphrase: 'persisted-secret',
    );
    expect(
      () => service.unlockWithPassphrase(
        userId: 'usr-legacy',
        passphrase: 'persisted-secret',
        saltBase64: setup.saltBase64,
        expectedCheckHash: 'deadbeef',
        iterations: setup.iterations,
      ),
      throwsA(
        isA<InvalidE2eePassphraseException>().having(
          (InvalidE2eePassphraseException e) => e.message,
          'message',
          contains('older build'),
        ),
      ),
    );
  });

  test('restoreKeyFromStore restores cipher if already unlocked on device', () async {
    const String userId = 'usr-789';
    await service.setupPassphrase(
      userId: userId,
      passphrase: 'persisted-secret',
    );
    final List<int> aad = <int>[1, 2, 3];
    final String sealed = await service.cipher!.seal('note', aad: aad);

    // New service instance on same device with stored keyring
    final E2eeService freshInstance = E2eeService(secureStore: secureStore);
    expect(freshInstance.isUnlocked, isFalse);

    final bool restored = await freshInstance.tryRestoreFromKeyring(userId: userId);
    expect(restored, isTrue);
    expect(freshInstance.isUnlocked, isTrue);
    // The restored cipher is the same derived data key, so it opens what
    // the setup cipher sealed.
    expect(await freshInstance.cipher!.unseal(sealed, aad: aad), 'note');
  });

  group('wrapping (#297)', () {
    test('no key anywhere: both wrappers hand the plain dependency through, unsealed', () async {
      await service.followIdentity('u');
      final FakeSyncTransport inner = FakeSyncTransport();
      final MediaObjectStore store = _FakeMediaStore();
      final SyncTransport plain = service.wrapTransport(inner, ownerId: 'u');
      expect(plain, isNot(isA<EncryptedSyncTransport>()));
      final Map<String, Object?> row = <String, Object?>{'id': 'r', 'title': 'Plain', 'version': 1};
      await plain.push(SyncTable.recordings, <Map<String, Object?>>[row]);
      expect(inner.pushes.single.$2.single['title'], 'Plain');
      final MediaObjectStore plainStore = service.wrapMediaStore(store, ownerId: 'u');
      expect(plainStore, isNot(isA<EncryptedMediaStore>()));
      expect(await plainStore.download('k', maxBytes: 1).toList(), isEmpty);
    });

    test('a run for a user other than the followed one is refused, not sealed or sent plain', () async {
      // The gateway's identity moves before the auth controller notifies,
      // so a run can start with owner B while the service still holds A.
      await service.followIdentity('A');
      await service.setupPassphrase(userId: 'A', passphrase: 'pa');
      expect(() => service.wrapTransport(FakeSyncTransport(), ownerId: 'B'), throwsStateError);
      expect(() => service.wrapMediaStore(_FakeMediaStore(), ownerId: 'B'), throwsStateError);
      // And with no key at all, the same: not a plaintext run for B either.
      service.lock();
      expect(() => service.wrapTransport(FakeSyncTransport(), ownerId: 'B'), throwsStateError);
    });

    test('a key locked or forgotten while its restore is in flight does not land', () async {
      await service.setupPassphrase(userId: 'A', passphrase: 'pa');
      final _GatedSecureStore gated =
          _GatedSecureStore(secureStore, Completer<String?>());
      final E2eeService slow = E2eeService(secureStore: gated);
      final Future<void> restoring = slow.followIdentity('A');
      expect(slow.isRestoring, isTrue);
      slow.lock();
      expect(slow.isRestoring, isFalse);
      gated.gate.complete(await secureStore.read('ai.augustyniak.capture.e2ee.mek.A'));
      await restoring;
      expect(slow.isUnlocked, isFalse);
    });

    test('a keyring that never answers reads as no key after the timeout', () async {
      // The gate is never completed; only the timeout ends the restore.
      final E2eeService hung = E2eeService(
        secureStore: _GatedSecureStore(secureStore, Completer<String?>()),
        keyringTimeout: const Duration(milliseconds: 50),
      );
      await hung.followIdentity('A');
      expect(hung.isRestoring, isFalse);
      expect(hung.isUnlocked, isFalse);
      expect(hung.hasIdentity, isTrue);
    });

    test('a run that starts while the key is still being read is refused', () async {
      await service.setupPassphrase(userId: 'A', passphrase: 'pa');
      final _GatedSecureStore gated =
          _GatedSecureStore(secureStore, Completer<String?>());
      final E2eeService slow = E2eeService(secureStore: gated);
      final Future<void> restoring = slow.followIdentity('A');
      expect(() => slow.wrapTransport(FakeSyncTransport(), ownerId: 'A'), throwsStateError);
      gated.gate.complete(await secureStore.read('ai.augustyniak.capture.e2ee.mek.A'));
      await restoring;
      expect(slow.wrapTransport(FakeSyncTransport(), ownerId: 'A'), isA<EncryptedSyncTransport>());
    });

    test('set-up for another user than the followed one is refused', () async {
      await service.followIdentity('A');
      expect(
        () => service.setupPassphrase(userId: 'B', passphrase: 'pb'),
        throwsStateError,
      );
      expect(service.isUnlocked, isFalse);
    });

    test('unlocked, both wrappers seal the dependency', () async {
      await service.setupPassphrase(userId: 'u', passphrase: 'p');
      expect(
        service.wrapTransport(FakeSyncTransport(), ownerId: 'u'),
        isA<EncryptedSyncTransport>(),
      );
      expect(
        service.wrapMediaStore(_FakeMediaStore(), ownerId: 'u'),
        isA<EncryptedMediaStore>(),
      );
    });

    test('following a user with no stored key drops the previous user\'s key first', () async {
      // A to B where B never set a passphrase: B's rows must not be sealed
      // under A's key with B's owner id — nothing could ever open them. The
      // drop has to happen *before* the keyring is read, because a sync run
      // can start while that read is in flight; so the assertion is made
      // inside that window, with the read held open.
      final _GatedSecureStore gated =
          _GatedSecureStore(secureStore, Completer<String?>());
      final E2eeService slow = E2eeService(
        secureStore: gated,
        kdf: E2eeKeyDerivation(iterations: 1000),
      );
      await slow.setupPassphrase(userId: 'A', passphrase: 'pa');
      final Future<void> a = slow.followIdentity('A');
      gated.gate.complete(await secureStore.read('ai.augustyniak.capture.e2ee.mek.A'));
      await a;
      expect(slow.isUnlocked, isTrue);

      gated.gate = Completer<String?>();
      final Future<void> b = slow.followIdentity('B');
      expect(slow.isUnlocked, isFalse,
          reason: "A's key must be gone before B's is even looked up");
      expect(slow.hasIdentity, isTrue);
      gated.gate.complete(null);
      await b;
      expect(slow.isUnlocked, isFalse);

      await slow.followIdentity(null);
      expect(slow.hasIdentity, isFalse);
      expect(slow.isUnlocked, isFalse);
    });

    test('following restores the user\'s own key from the keyring', () async {
      await service.setupPassphrase(userId: 'A', passphrase: 'pa');
      final E2eeService fresh = E2eeService(secureStore: secureStore);
      expect(fresh.isUnlocked, isFalse);
      await fresh.followIdentity('A');
      expect(fresh.isUnlocked, isTrue);
      // Same id again: a no-op, the cipher object is not replaced.
      final E2eeCipher? held = fresh.cipher;
      await fresh.followIdentity('A');
      expect(identical(fresh.cipher, held), isTrue);
    });

    test('a restore that lands after a sign-out is discarded', () async {
      await service.setupPassphrase(userId: 'A', passphrase: 'pa');
      final Completer<String?> gate = Completer<String?>();
      final E2eeService slow = E2eeService(
        secureStore: _GatedSecureStore(secureStore, gate),
      );
      final Future<void> restoring = slow.followIdentity('A');
      await slow.followIdentity(null);
      gate.complete(await secureStore.read('ai.augustyniak.capture.e2ee.mek.A'));
      await restoring;
      expect(slow.isUnlocked, isFalse,
          reason: 'the key read for A must not be held while signed out');
    });

    test('the service notifies on every key change so the sync status can follow', () async {
      int notified = 0;
      service.addListener(() => notified++);
      await service.setupPassphrase(userId: 'u', passphrase: 'p');
      expect(notified, 1);
      service.lock();
      expect(notified, 2);
      expect(await service.tryRestoreFromKeyring(userId: 'u'), isTrue);
      expect(notified, 3);
      await service.forgetKey(userId: 'u');
      expect(notified, 4);
    });
  });

  group('passphrase flow (#317)', () {
    late FakeE2eeSettingsStore settings;
    late E2eeService device;

    E2eeService newDevice({InMemorySecureStore? keyring}) {
      final E2eeService other = E2eeService(
        secureStore: keyring ?? InMemorySecureStore(),
        kdf: E2eeKeyDerivation(iterations: 1000),
        settings: settings,
        keyringTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(other.dispose);
      return other;
    }

    setUp(() {
      settings = FakeE2eeSettingsStore();
      device = newDevice(keyring: secureStore);
    });

    test('no row: set-up derives a key and publishes its parameters', () async {
      await device.followIdentity('u');
      expect(device.isPlaintextUnconfirmed, isTrue);
      await device.enroll('correct horse');
      final E2eePublicParams? row = settings.rows['u'];
      expect(row, isNotNull);
      expect(row!.iterations, 1000);
      expect(row.keyCheckHash, startsWith(E2eeKeyDerivation.keyCheckPrefix));
      expect(row.algorithm, 'pbkdf2_sha256');
      expect(device.isUnlocked, isTrue);
      expect(device.keyOnServer, isTrue);
      expect(secureStore.values, contains('ai.augustyniak.capture.e2ee.mek.u'));
      expect(device.wrapTransport(FakeSyncTransport(), ownerId: 'u'), isA<EncryptedSyncTransport>());
    });

    test('the default derivation publishes E2eeKeyDerivation.defaultIterations', () async {
      final E2eeService stock = E2eeService(secureStore: InMemorySecureStore(), settings: settings);
      addTearDown(stock.dispose);
      await stock.followIdentity('u');
      await stock.enroll('correct horse');
      expect(settings.rows['u']!.iterations, E2eeKeyDerivation.defaultIterations);
    });

    test('row present: unlock with the right passphrase, a wrong one is refused and stays locked', () async {
      await device.followIdentity('u');
      await device.enroll('correct horse');

      final E2eeService second = newDevice();
      await second.followIdentity('u');
      expect(second.isLocked, isTrue);
      expect(second.isUnlocked, isFalse);

      await expectLater(second.unlock('wrong horse'), throwsA(isA<InvalidE2eePassphraseException>()));
      expect(second.isUnlocked, isFalse);
      expect(second.isLocked, isTrue);
      expect(() => second.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);

      await second.unlock('correct horse');
      expect(second.isUnlocked, isTrue);
      // Both devices derived the same key: what one sealed the other opens.
      final E2eeCipher a = device.cipher!;
      final E2eeCipher b = second.cipher!;
      final List<int> aad = utf8.encode('u');
      final String sealed = await a.seal('note', aad: aad);
      expect(await b.unseal(sealed, aad: aad), 'note');
    });

    test('a second device finds the account encrypted: locked, and runs are refused, not plaintext', () async {
      await device.followIdentity('u');
      await device.enroll('correct horse');
      final E2eeService second = newDevice();
      await second.followIdentity('u');
      expect(second.keyOnServer, isTrue);
      expect(second.isLocked, isTrue);
      expect(second.isPlaintext, isFalse);
      expect(
        () => second.wrapTransport(FakeSyncTransport(), ownerId: 'u'),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('locked'))),
      );
      expect(() => second.wrapMediaStore(_FakeMediaStore(), ownerId: 'u'), throwsStateError);
    });

    test('losing the set-up race activates nothing and reports the conflict', () async {
      await device.followIdentity('u');
      final E2eeService second = newDevice();
      await second.followIdentity('u');
      await second.enroll('their horse');
      final String winner = settings.rows['u']!.keyCheckHash;
      // This device still believes there is no row; its insert must not win.
      await expectLater(device.enroll('my horse'), throwsA(isA<E2eeSettingsConflictException>()));
      expect(device.isUnlocked, isFalse);
      expect(secureStore.values, isEmpty);
      expect(settings.rows['u']!.keyCheckHash, winner);
      // The row exists, so from here this device is locked, not plaintext.
      expect(device.keyOnServer, isTrue);
      expect(device.isLocked, isTrue);
      expect(device.isPlaintext, isFalse);
      expect(() => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
      // And it can now unlock with the passphrase that won.
      await device.unlock('their horse');
      expect(device.isUnlocked, isTrue);
    });

    test('a failed row write leaves no key held, and nothing plain until the row is re-read', () async {
      await device.followIdentity('u');
      settings.createError = StateError('offline');
      await expectLater(device.enroll('correct horse'), throwsStateError);
      expect(device.isUnlocked, isFalse);
      expect(secureStore.values, isEmpty);
      // The insert may have committed server-side; nobody knows.
      expect(device.keyOnServer, isNull);
      expect(device.isLocked, isTrue);
      expect(() => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
      // `unlock` re-reads: no row after all, so set-up is offered again.
      settings.createError = null;
      await expectLater(device.unlock('correct horse'), throwsA(isA<E2eeNotSetUpException>()));
      expect(device.keyOnServer, isFalse);
      expect(device.isPlaintextUnconfirmed, isTrue);
    });

    test('a plaintext run re-checks the row and is refused once another device set up', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final FakeSyncTransport inner = FakeSyncTransport();
      final SyncTransport plain = device.wrapTransport(inner, ownerId: 'u');
      expect(plain, isNot(isA<EncryptedSyncTransport>()));
      // No row: the run goes through to the plain transport.
      await plain.push(SyncTable.recordings, <Map<String, Object?>>[]);
      expect(inner.pushes, hasLength(1));

      final E2eeService second = newDevice();
      await second.followIdentity('u');
      await second.enroll('their horse!');

      // The service still says plaintext (read once, at sign-in)...
      expect(device.isPlaintext, isTrue);
      final SyncTransport guarded = device.wrapTransport(FakeSyncTransport(), ownerId: 'u');
      final MediaObjectStore guardedStore = device.wrapMediaStore(_FakeMediaStore(), ownerId: 'u');
      // ...but the run asks again before its first call, and is refused.
      await expectLater(
        guarded.push(SyncTable.recordings, <Map<String, Object?>>[]),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('another device'))),
      );
      await expectLater(guardedStore.exists('k'), throwsStateError);
      expect(device.keyOnServer, isTrue);
      expect(device.isLocked, isTrue);
      expect(() => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
    });

    test('a keyring that refuses the key leaves the device locked, not plaintext', () async {
      final E2eeService noKeyring = E2eeService(
        secureStore: _ReadOnlySecureStore(),
        kdf: E2eeKeyDerivation(iterations: 1000),
        settings: settings,
      );
      addTearDown(noKeyring.dispose);
      await noKeyring.followIdentity('u');
      await expectLater(noKeyring.enroll('correct horse'), throwsStateError);
      // The row went up before the keyring refused, so the account is set
      // up and this device cannot seal: locked, every run refused.
      expect(settings.rows['u'], isNotNull);
      expect(noKeyring.isUnlocked, isFalse);
      expect(noKeyring.keyOnServer, isTrue);
      expect(noKeyring.isLocked, isTrue);
      expect(() => noKeyring.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
    });

    test('a plaintext run whose re-check fails is refused alone; the account stays plaintext', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final SyncTransport plain = device.wrapTransport(FakeSyncTransport(), ownerId: 'u');
      settings.readError = StateError('offline');
      await expectLater(
        plain.serverNow(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('could not check'))),
      );
      // An offline blip must not pin an account that never set up to locked.
      expect(device.keyOnServer, isFalse);
      expect(device.isPlaintext, isTrue);
      settings.readError = null;
      final FakeSyncTransport inner = FakeSyncTransport();
      final SyncTransport next = device.wrapTransport(inner, ownerId: 'u');
      await next.pull(SyncTable.recordings, since: null, after: null, limit: 10);
      expect(await next.serverNow(), isA<DateTime>());
    });

    test('a re-check answer that lands after this device set up is dropped', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final Completer<void> gate = settings.readGate = Completer<void>();
      final SyncTransport plain = device.wrapTransport(FakeSyncTransport(), ownerId: 'u');
      final Future<DateTime> run = plain.serverNow();
      for (int i = 0; i < 200 && settings.reads == 1; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      settings.readGate = null;
      await device.enroll('correct horse');
      expect(device.isUnlocked, isTrue);
      gate.complete(); // the stale "no row" arrives now
      await run;
      expect(device.keyOnServer, isTrue);
      device.lock();
      expect(device.isLocked, isTrue);
      expect(device.isPlaintext, isFalse);
    });

    test('a sign-out during set-up activates nothing, for anyone', () async {
      await device.followIdentity('u');
      settings.createGate = Completer<void>();
      final Future<void> enrolling = device.enroll('correct horse');
      for (int i = 0; i < 200 && settings.creates == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(settings.creates, 1);
      await device.followIdentity(null);
      settings.createGate!.complete();
      await expectLater(enrolling, throwsStateError);
      expect(device.hasIdentity, isFalse);
      expect(device.isUnlocked, isFalse);
      expect(secureStore.values, isEmpty);
      // The row was inserted for u — that is u's, and u can unlock with it.
      expect(settings.rows['u'], isNotNull);
    });

    test('a sign-out during the keyring write holds no key', () async {
      final _GatedSecureStore gated = _GatedSecureStore(secureStore, Completer<String?>()..complete(null));
      final E2eeService slow = E2eeService(
        secureStore: gated,
        kdf: E2eeKeyDerivation(iterations: 1000),
        settings: settings,
      );
      addTearDown(slow.dispose);
      await slow.followIdentity('u');
      final Completer<void> writeGate = gated.writeGate = Completer<void>();
      final Future<void> enrolling = slow.enroll('correct horse');
      // Let the derivation and the row insert run up to the keyring write.
      for (int i = 0; i < 200 && gated.writes == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(gated.writes, 1);
      expect(settings.rows['u'], isNotNull);
      await slow.followIdentity(null);
      writeGate.complete();
      await expectLater(enrolling, throwsStateError);
      expect(slow.isUnlocked, isFalse);
      expect(slow.hasIdentity, isFalse);
    });

    test('a user switch during unlock lands no key under the new user', () async {
      await device.followIdentity('u');
      await device.enroll('correct horse');
      final E2eeService second = newDevice();
      await second.followIdentity('u');
      final Completer<void> gate = settings.readGate = Completer<void>();
      final Future<void> unlocking = second.unlock('correct horse');
      await Future<void>.delayed(Duration.zero);
      settings.readGate = null; // v's own lookup is not held
      final Future<void> following = second.followIdentity('v');
      gate.complete(); // u's row now arrives, after the identity moved on
      await expectLater(unlocking, throwsStateError);
      await following;
      expect(second.isUnlocked, isFalse);
      expect(second.keyOnServer, isFalse); // v has no row
      expect(secureStore.values.keys, isNot(contains('ai.augustyniak.capture.e2ee.mek.v')));
    });

    test('an unanswered or failed row lookup refuses runs rather than reading as "no key"', () async {
      settings.readError = StateError('offline');
      await device.followIdentity('u');
      expect(device.keyOnServer, isNull);
      expect(device.isLocked, isTrue);
      expect(
        () => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('could not check'))),
      );

      settings.readError = null;
      settings.readGate = Completer<void>();
      final E2eeService slow = newDevice();
      final Future<void> restoring = slow.followIdentity('u');
      expect(slow.isRestoring, isTrue);
      await restoring; // 50 ms timeout
      expect(slow.keyOnServer, isNull);
      expect(() => slow.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
    });

    test('lock keeps the account encrypted: this device is locked, not plaintext', () async {
      await device.followIdentity('u');
      await device.enroll('correct horse');
      device.lock();
      expect(device.isLocked, isTrue);
      expect(device.isPlaintext, isFalse);
      expect(() => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'), throwsStateError);
      await device.forgetKey(userId: 'u');
      expect(secureStore.values, isEmpty);
      expect(device.isLocked, isTrue);
      // The row is still there, so the next launch finds the device locked.
      final E2eeService relaunch = newDevice(keyring: secureStore);
      await relaunch.followIdentity('u');
      expect(relaunch.isLocked, isTrue);
    });

    test('a keyring key skips the server lookup; a restored device is unlocked', () async {
      await device.followIdentity('u');
      await device.enroll('correct horse');
      settings.reads = 0;
      final E2eeService relaunch = newDevice(keyring: secureStore);
      await relaunch.followIdentity('u');
      expect(relaunch.isUnlocked, isTrue);
      expect(relaunch.keyOnServer, isTrue);
      expect(settings.reads, 0);
    });

    const String okKey = 'ai.augustyniak.capture.e2ee.plaintext-ok.u';

    test('no row on a fresh device: plaintext is unconfirmed, runs are refused until confirmed', () async {
      await device.followIdentity('u');
      expect(device.keyOnServer, isFalse);
      expect(device.isPlaintextUnconfirmed, isTrue);
      expect(device.isPlaintext, isFalse);
      expect(device.isLocked, isFalse);
      expect(
        () => device.wrapTransport(FakeSyncTransport(), ownerId: 'u'),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('confirm'))),
      );
      expect(() => device.wrapMediaStore(_FakeMediaStore(), ownerId: 'u'), throwsStateError);

      await device.confirmPlaintext();
      expect(device.isPlaintext, isTrue);
      expect(device.isPlaintextUnconfirmed, isFalse);
      final FakeSyncTransport inner = FakeSyncTransport();
      final SyncTransport plain = device.wrapTransport(inner, ownerId: 'u');
      await plain.push(SyncTable.recordings, <Map<String, Object?>>[]);
      expect(inner.pushes, hasLength(1));
      expect(secureStore.values[okKey], '1');
    });

    test('the confirmation survives a relaunch and a reinstall asks again', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final E2eeService relaunch = newDevice(keyring: secureStore);
      await relaunch.followIdentity('u');
      expect(relaunch.isPlaintext, isTrue);
      expect(relaunch.isPlaintextUnconfirmed, isFalse);
      final E2eeService reinstall = newDevice();
      await reinstall.followIdentity('u');
      expect(reinstall.isPlaintextUnconfirmed, isTrue);
      expect(reinstall.isPlaintext, isFalse);
    });

    test('a keyring that never answers asks again rather than allowing plaintext', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final E2eeService hung = E2eeService(
        secureStore: _GatedSecureStore(secureStore, Completer<String?>()),
        kdf: E2eeKeyDerivation(iterations: 1000),
        settings: settings,
        keyringTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(hung.dispose);
      await hung.followIdentity('u');
      expect(hung.isPlaintextUnconfirmed, isTrue);
    });

    test('set-up clears the confirmation', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      expect(secureStore.values, contains(okKey));
      await device.enroll('correct horse');
      expect(secureStore.values, isNot(contains(okKey)));
      expect(device.isPlaintext, isFalse);
      expect(device.isUnlocked, isTrue);
    });

    test('another device setting up clears the confirmation', () async {
      await device.followIdentity('u');
      await device.confirmPlaintext();
      final SyncTransport guarded = device.wrapTransport(FakeSyncTransport(), ownerId: 'u');
      final E2eeService second = newDevice();
      await second.followIdentity('u');
      await second.confirmPlaintext();
      await second.enroll('their horse!');
      await expectLater(guarded.serverNow(), throwsStateError);
      for (int i = 0; i < 200 && secureStore.values.containsKey(okKey); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(secureStore.values, isNot(contains(okKey)));
      expect(device.isLocked, isTrue);
      expect(device.isPlaintext, isFalse);
    });

    test('confirmPlaintext is refused while locked, restoring, or unlocked', () async {
      await expectLater(device.confirmPlaintext(), throwsStateError); // no identity

      final E2eeService other = newDevice();
      await other.followIdentity('v');
      await other.enroll('correct horse');
      other.lock();
      await expectLater(other.confirmPlaintext(), throwsStateError); // locked

      await device.followIdentity('u');
      await device.enroll('correct horse');
      await expectLater(device.confirmPlaintext(), throwsStateError); // unlocked

      settings.readGate = Completer<void>();
      final E2eeService slow = newDevice();
      final Future<void> restoring = slow.followIdentity('w');
      expect(slow.isRestoring, isTrue);
      await expectLater(slow.confirmPlaintext(), throwsStateError); // restoring
      await restoring;
      await expectLater(slow.confirmPlaintext(), throwsStateError); // lookup failed: unknown
      expect(slow.isPlaintext, isFalse);
    });

    test('a keyring write failure still confirms for this session', () async {
      final E2eeService noKeyring = E2eeService(
        secureStore: _ReadOnlySecureStore(),
        kdf: E2eeKeyDerivation(iterations: 1000),
        settings: settings,
      );
      addTearDown(noKeyring.dispose);
      await noKeyring.followIdentity('u');
      await noKeyring.confirmPlaintext();
      expect(noKeyring.isPlaintext, isTrue);
      expect(noKeyring.wrapTransport(FakeSyncTransport(), ownerId: 'u'), isNotNull);
    });

    test('enroll and unlock need a followed identity and a settings store', () async {
      await expectLater(device.enroll('correct horse'), throwsStateError);
      await expectLater(device.unlock('correct horse'), throwsStateError);
      await service.followIdentity('u'); // `service` has no settings store
      await expectLater(service.enroll('correct horse'), throwsStateError);
      await device.followIdentity('u');
      await expectLater(device.unlock('correct horse'), throwsA(isA<E2eeNotSetUpException>())); // no row
      expect(device.keyOnServer, isFalse);
    });
  });
}

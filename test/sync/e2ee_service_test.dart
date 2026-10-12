import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_media_store.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';

import 'fake_sync_transport.dart';

class _FakeMediaStore implements MediaObjectStore {
  @override
  Future<bool> exists(String key) async => false;

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {}

  @override
  Future<List<int>> download(String key) async => const <int>[];
}

/// Answers `read` only once [gate] completes, to order a slow keyring read
/// after a later identity change.
class _GatedSecureStore implements SecureValueStore {
  _GatedSecureStore(this.inner, this.gate);

  final SecureValueStore inner;
  Completer<String?> gate;

  @override
  Future<bool> containsKey(String key) => inner.containsKey(key);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<String?> read(String key) => gate.future;

  @override
  Future<void> write(String key, String value) => inner.write(key, value);
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
    test('locked, both wrappers hand back the plain dependency untouched', () async {
      await service.followIdentity('u');
      final SyncTransport inner = FakeSyncTransport();
      final MediaObjectStore store = _FakeMediaStore();
      expect(identical(service.wrapTransport(inner, ownerId: 'u'), inner), isTrue);
      expect(identical(service.wrapMediaStore(store, ownerId: 'u'), store), isTrue);
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
}

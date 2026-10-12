import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';

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
}

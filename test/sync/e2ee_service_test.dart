import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:augustyniak_capture/features/sync/data/e2ee_service.dart';

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
    service = E2eeService(secureStore: secureStore);
  });

  test('setupNewPassphrase initializes salt, check hash and active cipher', () async {
    const userId = 'usr-123';
    final params = await service.setupPassphrase(
      userId: userId,
      passphrase: 'correct-horse-battery',
    );

    expect(params.saltBase64, isNotEmpty);
    expect(params.keyCheckHash, isNotEmpty);
    expect(service.isUnlocked, isTrue);
    expect(service.cipher, isNotNull);

    // Verify MEK is persisted securely in keyring
    final storedMek = await secureStore.read('ai.augustyniak.capture.e2ee.mek.$userId');
    expect(storedMek, isNotNull);
  });

  test('unlockWithPassphrase succeeds with correct passphrase and rejects wrong one', () async {
    const userId = 'usr-456';
    final setup = await service.setupPassphrase(
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
      ),
      throwsA(isA<InvalidE2eePassphraseException>()),
    );
    expect(service.isUnlocked, isFalse);

    // Succeed with correct passphrase
    final unlocked = await service.unlockWithPassphrase(
      userId: userId,
      passphrase: 'my-strong-password',
      saltBase64: setup.saltBase64,
      expectedCheckHash: setup.keyCheckHash,
    );

    expect(unlocked, isTrue);
    expect(service.isUnlocked, isTrue);
    expect(service.cipher, isNotNull);
  });

  test('restoreKeyFromStore restores cipher if already unlocked on device', () async {
    const userId = 'usr-789';
    await service.setupPassphrase(
      userId: userId,
      passphrase: 'persisted-secret',
    );

    // New service instance on same device with stored keyring
    final freshInstance = E2eeService(secureStore: secureStore);
    expect(freshInstance.isUnlocked, isFalse);

    final restored = await freshInstance.tryRestoreFromKeyring(userId: userId);
    expect(restored, isTrue);
    expect(freshInstance.isUnlocked, isTrue);
    expect(freshInstance.cipher, isNotNull);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../auth/data/secure_auth_storage.dart';
import '../domain/e2ee_cipher.dart';

class InvalidE2eePassphraseException implements Exception {
  const InvalidE2eePassphraseException([this.message = 'Invalid E2EE passphrase']);
  final String message;

  @override
  String toString() => 'InvalidE2eePassphraseException: $message';
}

class E2eePublicParams {
  const E2eePublicParams({
    required this.saltBase64,
    required this.keyCheckHash,
    this.algorithm = 'pbkdf2_sha256',
  });

  final String saltBase64;
  final String keyCheckHash;
  final String algorithm;
}

/// Service managing the client-side lifecycle of the E2EE Master Encryption Key (MEK).
///
/// Keys are stored in the OS keyring via [SecureValueStore] or held in memory.
/// Neither the user's passphrase nor the unencrypted MEK is ever sent to the server.
class E2eeService {
  E2eeService({
    SecureValueStore? secureStore,
    E2eeKeyDerivation? kdf,
  })  : _secureStore = secureStore ?? const FlutterSecureValueStore(),
        _kdf = kdf ?? E2eeKeyDerivation();

  final SecureValueStore _secureStore;
  final E2eeKeyDerivation _kdf;

  E2eeCipher? _cipher;

  bool get isUnlocked => _cipher != null;
  E2eeCipher? get cipher => _cipher;

  static String _keyStoreKey(String userId) =>
      'ai.augustyniak.capture.e2ee.mek.$userId';

  /// Sets up a new passphrase, generates a fresh salt, derives the 256-bit MEK,
  /// persists the MEK in the local OS keyring, and returns the public KDF parameters.
  Future<E2eePublicParams> setupPassphrase({
    required String userId,
    required String passphrase,
  }) async {
    final List<int> salt = _kdf.generateSalt();
    final SecretKey key = await _kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
    );
    final String keyCheckHash = await _kdf.computeKeyCheckHash(
      key: key,
      salt: salt,
    );

    final List<int> keyBytes = await key.extractBytes();
    await _secureStore.write(
      _keyStoreKey(userId),
      base64Encode(keyBytes),
    );

    _cipher = E2eeCipher(key: key);

    return E2eePublicParams(
      saltBase64: base64Encode(salt),
      keyCheckHash: keyCheckHash,
    );
  }

  /// Verifies a passphrase against the remote salt and keyCheckHash, derives the MEK,
  /// saves it to the local OS keyring, and activates encryption.
  /// Throws [InvalidE2eePassphraseException] if passphrase is incorrect.
  Future<bool> unlockWithPassphrase({
    required String userId,
    required String passphrase,
    required String saltBase64,
    required String expectedCheckHash,
  }) async {
    final Uint8List salt = base64Decode(saltBase64);
    final SecretKey key = await _kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
    );
    final String actualHash = await _kdf.computeKeyCheckHash(
      key: key,
      salt: salt,
    );

    if (actualHash != expectedCheckHash) {
      throw const InvalidE2eePassphraseException();
    }

    final List<int> keyBytes = await key.extractBytes();
    await _secureStore.write(
      _keyStoreKey(userId),
      base64Encode(keyBytes),
    );

    _cipher = E2eeCipher(key: key);
    return true;
  }

  /// Attempts to restore an already unlocked MEK from the local keyring on app launch.
  Future<bool> tryRestoreFromKeyring({required String userId}) async {
    try {
      final String? stored = await _secureStore.read(_keyStoreKey(userId));
      if (stored == null) return false;
      final Uint8List bytes = base64Decode(stored);
      if (bytes.length != 32) return false;

      _cipher = E2eeCipher(key: SecretKey(bytes));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Clears active cipher from memory.
  void lock() {
    _cipher = null;
  }

  /// Clears active cipher and removes MEK from local keyring.
  Future<void> forgetKey({required String userId}) async {
    _cipher = null;
    await _secureStore.delete(_keyStoreKey(userId));
  }
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

class E2eeDecryptionException implements Exception {
  const E2eeDecryptionException([this.message = 'Decryption failed']);
  final String message;

  @override
  String toString() => 'E2eeDecryptionException: $message';
}

/// Derives a 256-bit AES master key from a user passphrase and salt using PBKDF2-HMAC-SHA256.
class E2eeKeyDerivation {
  E2eeKeyDerivation({this.iterations = 100000});

  final int iterations;
  final Pbkdf2 _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  List<int> generateSalt([int length = 16]) {
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKey> deriveKey({
    required String passphrase,
    required List<int> salt,
  }) {
    return _pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
  }

  /// Produces a deterministic hash of (keyBytes || salt) to allow zero-knowledge
  /// verification of the passphrase without ever storing the passphrase or key.
  Future<String> computeKeyCheckHash({
    required SecretKey key,
    required List<int> salt,
  }) async {
    final List<int> keyBytes = await key.extractBytes();
    final List<int> combined = <int>[...keyBytes, ...salt];
    return crypto.sha256.convert(combined).toString();
  }
}

/// Zero-Knowledge authenticated encryption using AES-256-GCM.
/// Envelope format: `enc:v1:` + base64(12-byte nonce || ciphertext || 16-byte MAC).
class E2eeCipher {
  E2eeCipher({required SecretKey key}) : _key = key;

  static const String sealedPrefix = 'enc:v1:';
  static const int _macLengthBytes = 16;

  final SecretKey _key;
  final AesGcm _algorithm = AesGcm.with256bits();

  static bool isSealed(String? value) =>
      value != null && value.startsWith(sealedPrefix);

  /// Seals UTF-8 text into an authenticated envelope.
  Future<String> seal(String plaintext) async {
    final List<int> clearBytes = utf8.encode(plaintext);
    final List<int> boxBytes = await sealBytes(clearBytes);
    return '$sealedPrefix${base64Encode(boxBytes)}';
  }

  /// Unseals an authenticated envelope back into UTF-8 text.
  /// Throws [E2eeDecryptionException] on invalid key, corrupt data, or altered MAC.
  Future<String> unseal(String sealed) async {
    if (!isSealed(sealed)) {
      throw const E2eeDecryptionException('Not an E2EE sealed envelope');
    }
    final String b64 = sealed.substring(sealedPrefix.length);
    Uint8List boxBytes;
    try {
      boxBytes = base64Decode(b64);
    } catch (e) {
      throw E2eeDecryptionException('Corrupt base64 envelope: $e');
    }
    final List<int> clearBytes = await unsealBytes(boxBytes);
    try {
      return utf8.decode(clearBytes);
    } catch (e) {
      throw E2eeDecryptionException('Corrupt UTF-8 cleartext: $e');
    }
  }

  /// Seals arbitrary binary bytes (12-byte nonce || ciphertext || 16-byte MAC).
  Future<List<int>> sealBytes(List<int> clearBytes) async {
    final SecretBox box = await _algorithm.encrypt(
      clearBytes,
      secretKey: _key,
    );
    return box.concatenation();
  }

  /// Unseals binary bytes. Throws [E2eeDecryptionException] on failure.
  Future<List<int>> unsealBytes(List<int> boxBytes) async {
    try {
      final SecretBox box = SecretBox.fromConcatenation(
        boxBytes,
        nonceLength: AesGcm.defaultNonceLength,
        macLength: _macLengthBytes,
      );
      return await _algorithm.decrypt(box, secretKey: _key);
    } catch (e) {
      throw E2eeDecryptionException('Authentication failed or invalid key: $e');
    }
  }
}

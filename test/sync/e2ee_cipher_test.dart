import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';

void main() {
  group('E2eeKeyDerivation', () {
    test('derives a 256-bit key from passphrase and salt', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final List<int> salt = kdf.generateSalt();
      expect(salt.length, 16);

      final key1 = await kdf.deriveKey(passphrase: 'correct-horse-battery', salt: salt);
      final key2 = await kdf.deriveKey(passphrase: 'correct-horse-battery', salt: salt);

      final bytes1 = await key1.extractBytes();
      final bytes2 = await key2.extractBytes();
      expect(bytes1.length, 32);
      expect(bytes1, equals(bytes2));
    });

    test('different passphrases or salts yield different keys', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final List<int> salt1 = kdf.generateSalt();
      final List<int> salt2 = kdf.generateSalt();

      final keyA = await kdf.deriveKey(passphrase: 'pass1', salt: salt1);
      final keyB = await kdf.deriveKey(passphrase: 'pass2', salt: salt1);
      final keyC = await kdf.deriveKey(passphrase: 'pass1', salt: salt2);

      final bytesA = await keyA.extractBytes();
      final bytesB = await keyB.extractBytes();
      final bytesC = await keyC.extractBytes();

      expect(bytesA, isNot(equals(bytesB)));
      expect(bytesA, isNot(equals(bytesC)));
    });

    test('computeKeyCheckHash matches only for identical key and salt', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final List<int> salt = kdf.generateSalt();

      final key1 = await kdf.deriveKey(passphrase: 'secret123', salt: salt);
      final key2 = await kdf.deriveKey(passphrase: 'wrong123', salt: salt);

      final hash1 = await kdf.computeKeyCheckHash(key: key1, salt: salt);
      final hash2 = await kdf.computeKeyCheckHash(key: key2, salt: salt);

      expect(hash1, isNotEmpty);
      expect(hash1, isNot(equals(hash2)));
    });
  });

  group('E2eeCipher', () {
    test('seals and unseals UTF-8 text with AES-256-GCM', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final salt = kdf.generateSalt();
      final key = await kdf.deriveKey(passphrase: 'test-passphrase', salt: salt);
      final cipher = E2eeCipher(key: key);

      const plaintext = 'Secret audio transcript: Meeting about zero knowledge E2EE';
      final sealed = await cipher.seal(plaintext);

      expect(sealed.startsWith('enc:v1:'), isTrue);
      expect(sealed, isNot(contains('transcript')));

      final unsealed = await cipher.unseal(sealed);
      expect(unsealed, equals(plaintext));
    });

    test('seals and unseals binary bytes', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final salt = kdf.generateSalt();
      final key = await kdf.deriveKey(passphrase: 'test-passphrase', salt: salt);
      final cipher = E2eeCipher(key: key);

      final clearBytes = utf8.encode('Raw audio file bytes simulated');
      final encryptedBytes = await cipher.sealBytes(clearBytes);

      expect(encryptedBytes, isNot(equals(clearBytes)));
      // Has 12 bytes nonce + clearBytes.length + 16 bytes MAC
      expect(encryptedBytes.length, clearBytes.length + 12 + 16);

      final decryptedBytes = await cipher.unsealBytes(encryptedBytes);
      expect(decryptedBytes, equals(clearBytes));
    });

    test('unseal throws E2eeDecryptionException on wrong key or altered ciphertext', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation();
      final salt = kdf.generateSalt();
      final key1 = await kdf.deriveKey(passphrase: 'pass-one', salt: salt);
      final key2 = await kdf.deriveKey(passphrase: 'pass-two', salt: salt);

      final cipher1 = E2eeCipher(key: key1);
      final cipher2 = E2eeCipher(key: key2);

      final sealed = await cipher1.seal('Private note');

      expect(() => cipher2.unseal(sealed), throwsA(isA<E2eeDecryptionException>()));

      // Corrupt ciphertext
      final corrupted = '${sealed.substring(0, sealed.length - 4)}AAAA';
      expect(() => cipher1.unseal(corrupted), throwsA(isA<E2eeDecryptionException>()));
    });
  });
}

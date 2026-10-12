import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';

/// Low enough that a derivation costs milliseconds; the count itself is
/// under test below, not the default.
const int _testIterations = 1000;

Future<E2eeCipher> _cipher(String passphrase, {List<int>? salt}) async {
  final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: _testIterations);
  final SecretKey key = await kdf.deriveKey(
    passphrase: passphrase,
    salt: salt ?? kdf.generateSalt(),
  );
  return E2eeCipher(key: key);
}

final List<int> _rowA = utf8.encode('owner-1\nrecordings\nrec-1');
final List<int> _rowB = utf8.encode('owner-1\nrecordings\nrec-2');

void main() {
  group('E2eeKeyDerivation', () {
    test('derives a 256-bit key from passphrase and salt', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: _testIterations);
      final List<int> salt = kdf.generateSalt();
      expect(salt.length, 16);

      final SecretKey key1 = await kdf.deriveKey(passphrase: 'correct-horse-battery', salt: salt);
      final SecretKey key2 = await kdf.deriveKey(passphrase: 'correct-horse-battery', salt: salt);

      final List<int> bytes1 = await key1.extractBytes();
      final List<int> bytes2 = await key2.extractBytes();
      expect(bytes1.length, 32);
      expect(bytes1, equals(bytes2));
    });

    test('different passphrases or salts yield different keys', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: _testIterations);
      final List<int> salt1 = kdf.generateSalt();
      final List<int> salt2 = kdf.generateSalt();

      final SecretKey keyA = await kdf.deriveKey(passphrase: 'pass1', salt: salt1);
      final SecretKey keyB = await kdf.deriveKey(passphrase: 'pass2', salt: salt1);
      final SecretKey keyC = await kdf.deriveKey(passphrase: 'pass1', salt: salt2);

      final List<int> bytesA = await keyA.extractBytes();
      final List<int> bytesB = await keyB.extractBytes();
      final List<int> bytesC = await keyC.extractBytes();

      expect(bytesA, isNot(equals(bytesB)));
      expect(bytesA, isNot(equals(bytesC)));
    });

    test('the iteration count is honoured, not a constant', () async {
      // Regression for the dead constructor parameter: `iterations` was
      // stored and ignored, and `Pbkdf2` was built with a literal 100000.
      final List<int> salt = List<int>.filled(16, 7);
      final SecretKey at1000 = await E2eeKeyDerivation(iterations: 1000)
          .deriveKey(passphrase: 'same', salt: salt);
      final SecretKey at2000 = await E2eeKeyDerivation(iterations: 2000)
          .deriveKey(passphrase: 'same', salt: salt);
      expect(
        await at1000.extractBytes(),
        isNot(equals(await at2000.extractBytes())),
      );
      expect(E2eeKeyDerivation(iterations: 2000).iterations, 2000);
    });

    test('the default iteration count follows current PBKDF2 guidance', () {
      expect(E2eeKeyDerivation().iterations, 600000);
      expect(E2eeKeyDerivation.defaultIterations, greaterThanOrEqualTo(600000));
    });

    test('an iteration count outside the bound is refused', () {
      // The count arrives from the server row on a second device: too low
      // weakens the key, too high pins the unlock for hours.
      expect(() => E2eeKeyDerivation(iterations: 999), throwsArgumentError);
      expect(() => E2eeKeyDerivation(iterations: 10000001), throwsArgumentError);
      expect(E2eeKeyDerivation(iterations: 1000).iterations, 1000);
      expect(E2eeKeyDerivation(iterations: 10000000).iterations, 10000000);
    });

    test('key check tag is versioned, key-bound and domain-separated', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: _testIterations);
      final List<int> salt = kdf.generateSalt();

      final SecretKey key1 = await kdf.deriveKey(passphrase: 'secret123', salt: salt);
      final SecretKey key2 = await kdf.deriveKey(passphrase: 'wrong123', salt: salt);

      final String tag1 = await kdf.computeKeyCheckHash(key: key1, salt: salt);
      final String tag1Again = await kdf.computeKeyCheckHash(key: key1, salt: salt);
      final String tag2 = await kdf.computeKeyCheckHash(key: key2, salt: salt);

      expect(tag1, startsWith(E2eeKeyDerivation.keyCheckPrefix));
      expect(tag1, equals(tag1Again));
      expect(tag1, isNot(equals(tag2)));

      // Not the old `sha256(key || salt)` — the tag must not be a plain hash
      // of the key bytes an attacker could relate to the data key.
      final List<int> keyBytes = await key1.extractBytes();
      final String plainHash =
          crypto.sha256.convert(<int>[...keyBytes, ...salt]).toString();
      expect(tag1, isNot(contains(plainHash)));
    });
  });

  group('E2eeCipher.forMasterKey', () {
    test('encrypts under a key derived from the master key, not the master key', () async {
      final SecretKey master = SecretKey(List<int>.generate(32, (int i) => i));
      final E2eeCipher derived = await E2eeCipher.forMasterKey(master);
      final E2eeCipher raw = E2eeCipher(key: master);

      final String sealed = await derived.seal('note', aad: _rowA);
      expect(await derived.unseal(sealed, aad: _rowA), 'note');
      expect(
        () => raw.unseal(sealed, aad: _rowA),
        throwsA(isA<E2eeDecryptionException>()),
      );

      // Deterministic: a second derivation from the same master key opens it.
      final E2eeCipher again = await E2eeCipher.forMasterKey(master);
      expect(await again.unseal(sealed, aad: _rowA), 'note');
    });
  });

  group('E2eeCipher', () {
    test('seals and unseals UTF-8 text with AES-256-GCM', () async {
      final E2eeCipher cipher = await _cipher('test-passphrase');

      const String plaintext = 'Secret audio transcript: Meeting about zero knowledge E2EE';
      final String sealed = await cipher.seal(plaintext, aad: _rowA);

      expect(sealed.startsWith('enc:v2:'), isTrue);
      expect(E2eeCipher.isSealed(sealed), isTrue);
      expect(sealed, isNot(contains('transcript')));

      final String unsealed = await cipher.unseal(sealed, aad: _rowA);
      expect(unsealed, equals(plaintext));
    });

    test('an envelope only opens under the associated data it was sealed with', () async {
      // The transplant case: a server moves `encrypted_payload` from rec-1
      // to rec-2. Same key, same bytes, different context — must fail.
      final E2eeCipher cipher = await _cipher('test-passphrase');
      final String sealed = await cipher.seal('rec-1 transcript', aad: _rowA);

      expect(
        () => cipher.unseal(sealed, aad: _rowB),
        throwsA(isA<E2eeDecryptionException>()),
      );
      expect(
        () => cipher.unseal(sealed, aad: const <int>[]),
        throwsA(isA<E2eeDecryptionException>()),
      );
      expect(await cipher.unseal(sealed, aad: _rowA), 'rec-1 transcript');
    });

    test('seals and unseals binary bytes bound to their key', () async {
      final E2eeCipher cipher = await _cipher('test-passphrase');
      final List<int> objectKey = utf8.encode('owner-1/rec-1/take.m4a');

      final List<int> clearBytes = utf8.encode('Raw audio file bytes simulated');
      final List<int> encryptedBytes = await cipher.sealBytes(clearBytes, aad: objectKey);

      expect(encryptedBytes, isNot(equals(clearBytes)));
      // Has 12 bytes nonce + clearBytes.length + 16 bytes MAC
      expect(encryptedBytes.length, clearBytes.length + 12 + 16);

      final List<int> decryptedBytes = await cipher.unsealBytes(encryptedBytes, aad: objectKey);
      expect(decryptedBytes, equals(clearBytes));

      expect(
        () => cipher.unsealBytes(encryptedBytes, aad: utf8.encode('owner-1/rec-2/take.m4a')),
        throwsA(isA<E2eeDecryptionException>()),
      );
    });

    test('unseal throws E2eeDecryptionException on wrong key or altered ciphertext', () async {
      final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: _testIterations);
      final List<int> salt = kdf.generateSalt();
      final E2eeCipher cipher1 = await _cipher('pass-one', salt: salt);
      final E2eeCipher cipher2 = await _cipher('pass-two', salt: salt);

      final String sealed = await cipher1.seal('Private note', aad: _rowA);

      expect(() => cipher2.unseal(sealed, aad: _rowA), throwsA(isA<E2eeDecryptionException>()));

      // Corrupt ciphertext
      final String corrupted = '${sealed.substring(0, sealed.length - 4)}AAAA';
      expect(() => cipher1.unseal(corrupted, aad: _rowA), throwsA(isA<E2eeDecryptionException>()));
    });

    test('a v1 envelope is recognised as sealed and refused', () async {
      final E2eeCipher cipher = await _cipher('test-passphrase');
      const String legacy = 'enc:v1:AAAA';
      expect(E2eeCipher.isSealed(legacy), isTrue);
      expect(
        () => cipher.unseal(legacy, aad: _rowA),
        throwsA(
          isA<E2eeDecryptionException>().having(
            (E2eeDecryptionException e) => e.message,
            'message',
            contains('enc:v1'),
          ),
        ),
      );
      expect(E2eeCipher.isSealed('plain text'), isFalse);
      expect(E2eeCipher.isSealed(null), isFalse);
    });
  });
}

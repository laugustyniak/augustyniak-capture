import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/domain/token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/aes_gcm_token_cipher.dart';

/// In-memory keyring stand-in, same hand-written-fake convention as
/// `_FakeSettingsRepository` in settings_test.dart.
class _MemoryKeyStore implements MasterKeyStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async {
    value = next;
  }
}

/// A keyring that is absent or locked: every call throws.
class _BrokenKeyStore implements MasterKeyStore {
  @override
  Future<String?> read() async => throw StateError('no keyring');

  @override
  Future<void> write(String next) async => throw StateError('no keyring');
}

void main() {
  group('TokenCipher.isSealed', () {
    test('detects the enc:v1: prefix', () {
      expect(TokenCipher.isSealed('enc:v1:abc'), isTrue);
      expect(TokenCipher.isSealed('sk-secret'), isFalse);
      expect(TokenCipher.isSealed(''), isFalse);
    });
  });

  group('PlaintextTokenCipher', () {
    const PlaintextTokenCipher cipher = PlaintextTokenCipher();

    test('does not encrypt', () {
      expect(cipher.encrypts, isFalse);
    });

    test('seal and unseal are identity transforms', () async {
      await cipher.ensureReady();
      expect(await cipher.seal('sk-secret'), 'sk-secret');
      expect(await cipher.unseal('sk-secret'), 'sk-secret');
      // A sealed blob passes through untouched — preservation, not decryption.
      expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
    });
  });

  group('AesGcmTokenCipher', () {
    test('ensureReady generates and persists a master key', () async {
      final _MemoryKeyStore store = _MemoryKeyStore();
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

      await cipher.ensureReady();

      expect(cipher.encrypts, isTrue);
      expect(store.value, isNotNull);
    });

    test('seal produces a prefixed blob and unseal round-trips it', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await cipher.ensureReady();

      final String sealed = await cipher.seal('sk-secret');

      expect(TokenCipher.isSealed(sealed), isTrue);
      expect(sealed, isNot(contains('sk-secret')));
      expect(await cipher.unseal(sealed), 'sk-secret');
    });

    test('sealing twice yields different blobs (random nonce)', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await cipher.ensureReady();

      expect(
        await cipher.seal('sk-secret'),
        isNot(await cipher.seal('sk-secret')),
      );
    });

    test('seal of an already-sealed value is a no-op', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await cipher.ensureReady();

      final String sealed = await cipher.seal('sk-secret');
      expect(await cipher.seal(sealed), sealed);
    });

    test('two ciphers sharing one store decrypt each other', () async {
      final _MemoryKeyStore store = _MemoryKeyStore();
      final AesGcmTokenCipher first = AesGcmTokenCipher(keyStore: store);
      await first.ensureReady();
      final String sealed = await first.seal('sk-secret');

      final AesGcmTokenCipher second = AesGcmTokenCipher(keyStore: store);
      await second.ensureReady();

      expect(await second.unseal(sealed), 'sk-secret');
    });

    test('unseal under the wrong key returns the blob unchanged', () async {
      final AesGcmTokenCipher first = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await first.ensureReady();
      final String sealed = await first.seal('sk-secret');

      // Different store, different generated key — a wiped keyring.
      final AesGcmTokenCipher second = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await second.ensureReady();

      expect(await second.unseal(sealed), sealed);
    });

    test('unseal of a corrupt blob returns it unchanged', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await cipher.ensureReady();

      expect(await cipher.unseal('enc:v1:not-base64!'), 'enc:v1:not-base64!');
    });

    test('a broken key store degrades to identity, never throws', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _BrokenKeyStore(),
      );
      await cipher.ensureReady();

      expect(cipher.encrypts, isFalse);
      expect(await cipher.seal('sk-secret'), 'sk-secret');
      expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
    });

    test(
      'a wrong-sized stored key is left untouched and disables encryption',
      () async {
        final _MemoryKeyStore store = _MemoryKeyStore();
        // Something else owns this entry: 16 bytes, not the 32 we require.
        store.value = base64Encode(List<int>.filled(16, 7));
        final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

        await cipher.ensureReady();

        expect(cipher.encrypts, isFalse);
        expect(store.value, base64Encode(List<int>.filled(16, 7)));
        expect(await cipher.seal('sk-secret'), 'sk-secret');
      },
    );
  });
}

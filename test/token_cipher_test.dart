import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/domain/token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/aes_gcm_token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/file_master_key_store.dart';
import 'package:augustyniak_capture/features/settings/data/secure_storage_master_key_store.dart';

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

/// A keyring that accepts a write and forgets it — the shape a keyring takes
/// when it answers success without persisting anything.
class _AmnesiacKeyStore implements MasterKeyStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String next) async {}
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

    test('a refusal keeps the keyring\'s own words', () async {
      // The whole point of the field: without it, an entitlement bug that kept
      // encryption off on every macOS launch looked identical to a Linux box
      // with no keyring daemon — both were one amber line reading "plaintext".
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _BrokenKeyStore(),
      );
      await cipher.ensureReady();

      expect(cipher.unavailableReason, contains('no keyring'));
    });

    test('a working cipher has nothing to explain', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      await cipher.ensureReady();

      expect(cipher.unavailableReason, isNull);
    });

    test('a store that accepts the key but drops it is reported', () async {
      // Sealing under a key the keyring never persisted would make every token
      // unreadable on the next launch, so this path stays off — and says why.
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _AmnesiacKeyStore(),
      );
      await cipher.ensureReady();

      expect(cipher.encrypts, isFalse);
      expect(cipher.unavailableReason, contains('did not store it'));
    });

    test('a wrong-sized stored key says whose entry it is', () async {
      final _MemoryKeyStore store = _MemoryKeyStore();
      store.value = base64Encode(List<int>.filled(16, 7));
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

      await cipher.ensureReady();

      expect(cipher.unavailableReason, contains('did not write'));
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

  group('FileMasterKeyStore', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('master-key-');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    FileMasterKeyStore store({MasterKeyStore? migrateFrom}) =>
        FileMasterKeyStore(
          directory: () async => dir,
          migrateFrom: migrateFrom,
        );

    test('reads nothing before anything is written', () async {
      expect(await store().read(), isNull);
    });

    test('round-trips a written key', () async {
      final String key = base64Encode(List<int>.filled(32, 3));
      await store().write(key);

      expect(await store().read(), key);
    });

    test('the key file is readable by its owner alone', () async {
      // The whole security argument for moving off the keyring: the key now
      // sits beside the database it protects, so the file mode is the only
      // thing between it and a careless `cp -R` of the support directory.
      await store().write(base64Encode(List<int>.filled(32, 3)));

      final File file = File('${dir.path}/${FileMasterKeyStore.fileName}');
      expect(file.statSync().modeString(), 'rw-------');
    }, skip: Platform.isWindows);

    test('adopts a key the previous store already holds', () async {
      // The migration that makes this change non-destructive: tokens sealed
      // under the keyring's key must still open after the switch.
      final _MemoryKeyStore keyring = _MemoryKeyStore();
      keyring.value = base64Encode(List<int>.filled(32, 9));

      expect(await store(migrateFrom: keyring).read(), keyring.value);
      // Adopted, not merely forwarded — the next launch needs no keyring.
      expect(await store().read(), keyring.value);
    });

    test('the file outranks the previous store once adopted', () async {
      final String own = base64Encode(List<int>.filled(32, 1));
      await store().write(own);

      final _MemoryKeyStore keyring = _MemoryKeyStore();
      keyring.value = base64Encode(List<int>.filled(32, 2));

      expect(await store(migrateFrom: keyring).read(), own);
    });

    test('a keyring that refuses is not an error here', () async {
      // The exact state this store exists to survive: an ad-hoc rebuild whose
      // signature the login keychain ACL no longer recognises.
      expect(await store(migrateFrom: _BrokenKeyStore()).read(), isNull);
    });

    test('a blank key file reads as absent, not as a broken key', () async {
      // A zero-length read must leave the cipher free to generate a new key.
      // Answering '' instead would decode to a wrong-sized key and wedge
      // encryption off permanently with no way back.
      File(
        '${dir.path}/${FileMasterKeyStore.fileName}',
      ).writeAsStringSync('\n');

      expect(await store().read(), isNull);
    });

    test(
      'a cipher on the migrated key opens tokens sealed before it',
      () async {
        // End to end, and the regression this whole change is for: a token
        // sealed while the keyring worked stays readable after the switch.
        final _MemoryKeyStore keyring = _MemoryKeyStore();
        final AesGcmTokenCipher before = AesGcmTokenCipher(keyStore: keyring);
        await before.ensureReady();
        final String sealed = await before.seal('sk-secret');

        final AesGcmTokenCipher after = AesGcmTokenCipher(
          keyStore: store(migrateFrom: keyring),
        );
        await after.ensureReady();

        expect(after.encrypts, isTrue);
        expect(await after.unseal(sealed), 'sk-secret');
      },
    );

    test('a rebuild that loses the keyring still decrypts', () async {
      // Same as above, one launch later: the keyring has stopped answering
      // (new cdhash, denied prompt) and only the adopted file remains.
      final _MemoryKeyStore keyring = _MemoryKeyStore();
      final AesGcmTokenCipher before = AesGcmTokenCipher(keyStore: keyring);
      await before.ensureReady();
      final String sealed = await before.seal('sk-secret');
      await store(migrateFrom: keyring).read();

      final AesGcmTokenCipher after = AesGcmTokenCipher(
        keyStore: store(migrateFrom: _BrokenKeyStore()),
      );
      await after.ensureReady();

      expect(await after.unseal(sealed), 'sk-secret');
    });
  });

  group('SecureStorageMasterKeyStore', () {
    test('macOS uses the classic keychain, not the data protection one', () {
      // The one line of this adapter that is not a pass-through, and the one
      // that decides whether encryption runs at all on macOS. The plugin
      // defaults it to true, which needs a `keychain-access-groups` entitlement
      // and therefore a Team-ID signature; this app is ad-hoc signed, so every
      // Keychain call answered -34018 and the tokens went to disk in plaintext
      // — reported as "keyring unavailable", the same words a headless Linux
      // box uses. Nothing else in the suite can see this decision: the value
      // only matters inside a platform channel no test reaches.
      expect(
        SecureStorageMasterKeyStore.macOsOptions
            .toMap()['useDataProtectionKeyChain'],
        'false',
      );
    });
  });
}

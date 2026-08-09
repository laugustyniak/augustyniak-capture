import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/domain/token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/aes_gcm_token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/file_master_key_store.dart';
import 'package:augustyniak_capture/features/settings/data/migrating_master_key_store.dart';
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

/// Accepts a read but refuses every write — a keyring present but locked for
/// writing, or a store with nowhere to put the value.
class _WriteOnlyFailsKeyStore implements MasterKeyStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String next) async => throw StateError('cannot write');
}

/// A store whose key is still there but cannot be read this launch: a key file
/// with the wrong mode, a keychain that answers "not found" to a rebuilt
/// binary. The distinction that matters is that a write here is destructive —
/// it lands on top of the only copy of the key.
class _UnreadableKeyStore implements MasterKeyStore {
  _UnreadableKeyStore(this.hidden);

  String hidden;

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String next) async {
    hidden = next;
  }
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

  group('AesGcmTokenCipher.expectExistingKey', () {
    test('a store answering nothing does not get a replacement key', () async {
      // The mine this guard exists for. `read()` returning null is ambiguous:
      // it is a first run *or* a key that is present and unreachable. Treating
      // the second as the first generates a fresh key, writes it over the only
      // copy of the real one, and makes every already-sealed token unopenable
      // for good — the one loss this whole layer is built to prevent.
      final _UnreadableKeyStore store = _UnreadableKeyStore('the-real-key');
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

      cipher.expectExistingKey();
      await cipher.ensureReady();

      expect(store.hidden, 'the-real-key');
      expect(cipher.encrypts, isFalse);
    });

    test(
      'the refusal says the key was expected, not that none exists',
      () async {
        // "no keyring here" and "your key is missing but your data needs it" are
        // opposite situations; the second must never be reported as the first.
        final AesGcmTokenCipher cipher = AesGcmTokenCipher(
          keyStore: _UnreadableKeyStore('the-real-key'),
        );

        cipher.expectExistingKey();
        await cipher.ensureReady();

        expect(cipher.unavailableReason, contains('already encrypted'));
      },
    );

    test('sealed values are preserved rather than re-encrypted', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _UnreadableKeyStore('the-real-key'),
      );
      cipher.expectExistingKey();
      await cipher.ensureReady();

      expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
      expect(await cipher.seal('enc:v1:blob'), 'enc:v1:blob');
    });

    test('the guard is irrelevant when the key store answers', () async {
      final _MemoryKeyStore store = _MemoryKeyStore();
      final AesGcmTokenCipher writer = AesGcmTokenCipher(keyStore: store);
      await writer.ensureReady();
      final String sealed = await writer.seal('sk-secret');

      final AesGcmTokenCipher reader = AesGcmTokenCipher(keyStore: store);
      reader.expectExistingKey();
      await reader.ensureReady();

      expect(reader.encrypts, isTrue);
      expect(await reader.unseal(sealed), 'sk-secret');
    });

    test('an unguarded first run still generates a key', () async {
      // The guard must stay opt-in: a genuine fresh install has no sealed data
      // to protect and has to be able to start encrypting.
      final _MemoryKeyStore store = _MemoryKeyStore();
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

      await cipher.ensureReady();

      expect(cipher.encrypts, isTrue);
      expect(store.value, isNotNull);
    });

    test(
      'a key kept safe by the guard opens the tokens when it returns',
      () async {
        // End to end, and the whole point: one launch without a readable key
        // must cost nothing permanent.
        final _MemoryKeyStore keyring = _MemoryKeyStore();
        final AesGcmTokenCipher before = AesGcmTokenCipher(keyStore: keyring);
        await before.ensureReady();
        final String sealed = await before.seal('sk-secret');

        final _UnreadableKeyStore blind = _UnreadableKeyStore(keyring.value!);
        final AesGcmTokenCipher during = AesGcmTokenCipher(keyStore: blind);
        during.expectExistingKey();
        await during.ensureReady();
        expect(await during.unseal(sealed), sealed);

        final AesGcmTokenCipher after = AesGcmTokenCipher(
          keyStore: _MemoryKeyStore()..value = blind.hidden,
        );
        await after.ensureReady();

        expect(await after.unseal(sealed), 'sk-secret');
      },
    );

    test('PlaintextTokenCipher accepts the call and ignores it', () async {
      // The repository announces this against the interface, so the default
      // implementation has to be a no-op rather than a missing method.
      const PlaintextTokenCipher cipher = PlaintextTokenCipher();

      cipher.expectExistingKey();
      await cipher.ensureReady();

      expect(cipher.encrypts, isFalse);
      expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
    });
  });

  group('MigratingMasterKeyStore', () {
    // The keyring is the primary store again now that builds carry a stable
    // signature, and the point of moving back is that the key stops sitting
    // next to the ciphertext it opens. That only pays off if the old file is
    // actually retired — but retiring it before the keyring has demonstrably
    // kept the key would destroy the only copy, which is the failure this
    // whole layer is built around.

    MigratingMasterKeyStore storeOver(
      MasterKeyStore primary,
      MasterKeyStore fallback, {
      void Function()? onRetire,
    }) => MigratingMasterKeyStore(
      primary: primary,
      fallback: fallback,
      retireFallback: onRetire == null ? null : () async => onRetire(),
    );

    test('a key in the primary store is used and nothing is retired', () async {
      final _MemoryKeyStore keyring = _MemoryKeyStore()..value = 'the-key';
      final _MemoryKeyStore file = _MemoryKeyStore()..value = 'stale';
      bool retired = false;

      final String? read = await storeOver(
        keyring,
        file,
        onRetire: () => retired = true,
      ).read();

      expect(read, 'the-key');
      expect(file.value, 'stale');
      expect(retired, isFalse);
    });

    test('a fallback holding the same key is retired, not left behind', () async {
      // The case this machine is actually in: both stores already hold the key,
      // because the previous arrangement copied it rather than moving it. With
      // retirement tied to the migration path alone, the file would survive
      // every launch and the point of moving back — the key no longer sitting
      // beside the ciphertext it opens — would quietly never happen.
      final _MemoryKeyStore keyring = _MemoryKeyStore()..value = 'the-key';
      final _MemoryKeyStore file = _MemoryKeyStore()..value = 'the-key';
      bool retired = false;

      final String? read = await storeOver(
        keyring,
        file,
        onRetire: () => retired = true,
      ).read();

      expect(read, 'the-key');
      expect(retired, isTrue);
    });

    test('a fallback holding a different key is left alone', () async {
      // Not a redundant copy but a second key, and the tokens on disk may be
      // sealed under it. Deleting it is the one irreversible mistake on offer.
      final _MemoryKeyStore keyring = _MemoryKeyStore()..value = 'new-key';
      final _MemoryKeyStore file = _MemoryKeyStore()..value = 'older-key';
      bool retired = false;

      await storeOver(keyring, file, onRetire: () => retired = true).read();

      expect(retired, isFalse);
      expect(file.value, 'older-key');
    });

    test(
      'a key found only in the fallback is adopted and the old one retired',
      () async {
        final _MemoryKeyStore keyring = _MemoryKeyStore();
        final _MemoryKeyStore file = _MemoryKeyStore()..value = 'the-key';
        bool retired = false;

        final String? read = await storeOver(
          keyring,
          file,
          onRetire: () => retired = true,
        ).read();

        expect(read, 'the-key');
        expect(keyring.value, 'the-key');
        expect(retired, isTrue);
      },
    );

    test('a primary that forgets the write keeps the fallback alive', () async {
      // The read-back is what separates "the keyring took it" from "the keyring
      // kept it". Retiring on the strength of a successful write alone is how
      // the only copy of a key disappears.
      final _AmnesiacKeyStore keyring = _AmnesiacKeyStore();
      final _MemoryKeyStore file = _MemoryKeyStore()..value = 'the-key';
      bool retired = false;

      final String? read = await storeOver(
        keyring,
        file,
        onRetire: () => retired = true,
      ).read();

      expect(read, 'the-key');
      expect(retired, isFalse);
      expect(file.value, 'the-key');
    });

    test('a primary that refuses the write keeps the fallback alive', () async {
      final _MemoryKeyStore file = _MemoryKeyStore()..value = 'the-key';
      bool retired = false;

      final String? read = await storeOver(
        _WriteOnlyFailsKeyStore(),
        file,
        onRetire: () => retired = true,
      ).read();

      expect(read, 'the-key');
      expect(retired, isFalse);
      expect(file.value, 'the-key');
    });

    test(
      'a refusing primary is reported, not papered over by the fallback',
      () async {
        // The deliberate break from the previous arrangement. A keyring that
        // throws is a failure the user has to see — falling through to the file
        // would hide it and quietly undo the security this move is for. The
        // cipher turns the throw into `unavailableReason`, and with sealed data
        // present the guard refuses to mint a replacement key.
        final _MemoryKeyStore file = _MemoryKeyStore()..value = 'the-key';

        expect(
          () => storeOver(_BrokenKeyStore(), file).read(),
          throwsA(isA<StateError>()),
        );
        expect(file.value, 'the-key');
      },
    );

    test('nothing anywhere reads as a first run', () async {
      final _MemoryKeyStore keyring = _MemoryKeyStore();
      bool retired = false;

      final String? read = await storeOver(
        keyring,
        _MemoryKeyStore(),
        onRetire: () => retired = true,
      ).read();

      expect(read, isNull);
      expect(retired, isFalse);
    });

    test('an unreadable fallback is not an error', () async {
      // A missing or unreadable key file on an install that never had one.
      expect(
        await storeOver(_MemoryKeyStore(), _BrokenKeyStore()).read(),
        isNull,
      );
    });

    test('writes go to the primary store only', () async {
      final _MemoryKeyStore keyring = _MemoryKeyStore();
      final _MemoryKeyStore file = _MemoryKeyStore();

      await storeOver(keyring, file).write('fresh');

      expect(keyring.value, 'fresh');
      expect(file.value, isNull);
    });

    test('a token sealed before the move still opens after it', () async {
      // End to end: the file held the key, the keyring takes it over, and the
      // blob written under the old arrangement is still readable.
      final _MemoryKeyStore file = _MemoryKeyStore();
      final AesGcmTokenCipher before = AesGcmTokenCipher(keyStore: file);
      await before.ensureReady();
      final String sealed = await before.seal('sk-secret');

      final _MemoryKeyStore keyring = _MemoryKeyStore();
      final AesGcmTokenCipher after = AesGcmTokenCipher(
        keyStore: storeOver(keyring, file),
      );
      await after.ensureReady();

      expect(after.encrypts, isTrue);
      expect(await after.unseal(sealed), 'sk-secret');
      expect(keyring.value, isNotNull);
    });
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

    test('delete removes the key file', () async {
      // What retires the old copy once the keyring has taken the key over.
      await store().write(base64Encode(List<int>.filled(32, 3)));
      final File file = File('${dir.path}/${FileMasterKeyStore.fileName}');
      expect(file.existsSync(), isTrue);

      await store().delete();

      expect(file.existsSync(), isFalse);
      expect(await store().read(), isNull);
    });

    test('deleting a key file that is not there is not an error', () async {
      // The handover is retried on every launch, so this runs again long after
      // it has already succeeded.
      await store().delete();
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

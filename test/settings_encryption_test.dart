import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/settings/data/aes_gcm_token_cipher.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/provider_profile.dart';
import 'package:augustyniak_capture/features/settings/domain/token_cipher.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

/// Same convention as `_FakeSettingsRepository` in settings_test.dart, but
/// keeps the real load/save/seal logic and only redirects the file: the one
/// path_provider touchpoint is `settingsFile()`, so overriding it lets the
/// full pipeline — atomic write included — run against a temp file.
class _TempFileSettingsRepository extends SettingsRepository {
  _TempFileSettingsRepository(this.file, {super.cipher});

  final File file;

  @override
  Future<File?> settingsFile() async => file;
}

class _FailingSaveSettingsRepository extends _TempFileSettingsRepository {
  _FailingSaveSettingsRepository(super.file, {super.cipher});

  @override
  Future<void> save(AppSettings settings) async {
    throw const FileSystemException('disk full');
  }
}

class _MemoryKeyStore implements MasterKeyStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async {
    value = next;
  }
}

/// A key store holding the real key but unable to hand it over this launch —
/// an unreadable key file, a keychain refusing a rebuilt binary. A write here
/// destroys the only copy, which is what makes it different from an empty one.
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

AppSettings _settingsWithToken(String? token) {
  return AppSettings(
    profiles: <ProviderProfile>[
      ProviderProfile(
        id: 'p1',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: token,
      ),
    ],
    activeProfileId: 'p1',
  );
}

void main() {
  group('ProviderProfile.usableBearerToken', () {
    test('passes a plaintext token through', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'sk-secret',
      );
      expect(profile.usableBearerToken, 'sk-secret');
    });

    test('is null for null and blank tokens', () {
      const ProviderProfile none = ProviderProfile(
        id: 'p',
        name: 'X',
        endpoint: 'https://example.com',
      );
      const ProviderProfile blank = ProviderProfile(
        id: 'p',
        name: 'X',
        endpoint: 'https://example.com',
        bearerToken: '   ',
      );
      expect(none.usableBearerToken, isNull);
      expect(blank.usableBearerToken, isNull);
    });

    test('is null for a still-sealed blob, and the service omits it', () {
      const ProviderProfile profile = ProviderProfile(
        id: 'p',
        name: 'OpenAI',
        endpoint: 'https://api.openai.com/v1/audio/transcriptions',
        bearerToken: 'enc:v1:unreadable-blob',
      );

      expect(profile.usableBearerToken, isNull);

      // The sealed blob must never reach an Authorization header.
      final HttpWhisperTranscriptionService service =
          profile.toService() as HttpWhisperTranscriptionService;
      expect(service.bearerToken, isNull);
    });
  });

  group('SettingsRepository token encryption', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'augustyniak_capture_settings_test',
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    File fileIn(Directory dir) => File('${dir.path}/settings.json');

    test('save seals the token; the plaintext never reaches disk', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

      await repository.save(_settingsWithToken('sk-secret'));

      final String raw = await fileIn(tempDir).readAsString();
      expect(raw, isNot(contains('sk-secret')));
      expect(raw, contains(TokenCipher.sealedPrefix));
    });

    test('load returns the plaintext token again (round trip)', () async {
      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

      await repository.save(_settingsWithToken('sk-secret'));
      final AppSettings? loaded = await repository.load();

      expect(loaded!.profiles.single.bearerToken, 'sk-secret');
    });

    test('a legacy plaintext file is migrated on load', () async {
      // Written by a build that predates encryption.
      await fileIn(
        tempDir,
      ).writeAsString(jsonEncode(_settingsWithToken('sk-secret').toJson()));

      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

      final AppSettings? loaded = await repository.load();

      expect(loaded!.profiles.single.bearerToken, 'sk-secret');
      final String raw = await fileIn(tempDir).readAsString();
      expect(raw, isNot(contains('sk-secret')));
      expect(raw, contains(TokenCipher.sealedPrefix));
    });

    test('without a cipher the file stays plaintext and untouched', () async {
      final String legacy = jsonEncode(
        _settingsWithToken('sk-secret').toJson(),
      );
      await fileIn(tempDir).writeAsString(legacy);

      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(fileIn(tempDir));

      final AppSettings? loaded = await repository.load();

      expect(loaded!.profiles.single.bearerToken, 'sk-secret');
      expect(await fileIn(tempDir).readAsString(), legacy);
      expect(repository.encryptsTokens, isFalse);
    });

    test('a blob sealed under a lost key survives load and re-save', () async {
      final AesGcmTokenCipher original = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _TempFileSettingsRepository writer = _TempFileSettingsRepository(
        fileIn(tempDir),
        cipher: original,
      );
      await writer.save(_settingsWithToken('sk-secret'));
      final String sealedOnDisk = await fileIn(tempDir).readAsString();

      // A wiped keyring: a fresh store generates a different key.
      final AesGcmTokenCipher wrongKey = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _TempFileSettingsRepository reader = _TempFileSettingsRepository(
        fileIn(tempDir),
        cipher: wrongKey,
      );

      final AppSettings? loaded = await reader.load();
      final String inMemory = loaded!.profiles.single.bearerToken!;

      // The blob is preserved in memory, unusable for requests…
      expect(TokenCipher.isSealed(inMemory), isTrue);
      expect(loaded.profiles.single.usableBearerToken, isNull);

      // …and a re-save writes the original blob back, not a re-encryption
      // of it and not null.
      await reader.save(loaded);
      expect(await fileIn(tempDir).readAsString(), sealedOnDisk);
    });

    test('load tells the cipher the stored data is already encrypted', () async {
      // Without this the repository asks for a key, is told there is none, and
      // a fresh one is written over the real one — which turns "this launch
      // cannot read your tokens" into "no launch ever will".
      final _MemoryKeyStore keyring = _MemoryKeyStore();
      await _TempFileSettingsRepository(
        fileIn(tempDir),
        cipher: AesGcmTokenCipher(keyStore: keyring),
      ).save(_settingsWithToken('sk-secret'));
      final String realKey = keyring.value!;

      final _UnreadableKeyStore blind = _UnreadableKeyStore(realKey);
      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(
            fileIn(tempDir),
            cipher: AesGcmTokenCipher(keyStore: blind),
          );

      final AppSettings? loaded = await repository.load();

      expect(blind.hidden, realKey);
      expect(loaded!.profiles.single.usableBearerToken, isNull);
    });

    test(
      'the key survives the blind launch, so the token opens later',
      () async {
        final _MemoryKeyStore keyring = _MemoryKeyStore();
        await _TempFileSettingsRepository(
          fileIn(tempDir),
          cipher: AesGcmTokenCipher(keyStore: keyring),
        ).save(_settingsWithToken('sk-secret'));

        final _UnreadableKeyStore blind = _UnreadableKeyStore(keyring.value!);
        await _TempFileSettingsRepository(
          fileIn(tempDir),
          cipher: AesGcmTokenCipher(keyStore: blind),
        ).load();

        // The key store can read again — a repaired file mode, a granted
        // keychain prompt. Nothing was lost in between.
        final AppSettings? recovered = await _TempFileSettingsRepository(
          fileIn(tempDir),
          cipher: AesGcmTokenCipher(
            keyStore: _MemoryKeyStore()..value = blind.hidden,
          ),
        ).load();

        expect(recovered!.profiles.single.bearerToken, 'sk-secret');
      },
    );

    test('a first run with no stored data still starts encrypting', () async {
      // The guard must not reach an install that has nothing to protect.
      final _MemoryKeyStore store = _MemoryKeyStore();
      final _TempFileSettingsRepository repository =
          _TempFileSettingsRepository(
            fileIn(tempDir),
            cipher: AesGcmTokenCipher(keyStore: store),
          );

      await repository.save(_settingsWithToken('sk-secret'));

      expect(store.value, isNotNull);
      expect(repository.encryptsTokens, isTrue);
      expect(
        await fileIn(tempDir).readAsString(),
        contains(TokenCipher.sealedPrefix),
      );
    });

    test('a failing migration write still returns the loaded settings, '
        'and leaves the file untouched', () async {
      final String legacy = jsonEncode(
        _settingsWithToken('sk-secret').toJson(),
      );
      await fileIn(tempDir).writeAsString(legacy);

      final AesGcmTokenCipher cipher = AesGcmTokenCipher(
        keyStore: _MemoryKeyStore(),
      );
      final _FailingSaveSettingsRepository repository =
          _FailingSaveSettingsRepository(fileIn(tempDir), cipher: cipher);

      // Must not throw: the migration save failing inside load() is
      // swallowed, not propagated.
      final AppSettings? loaded = await repository.load();

      expect(loaded!.profiles.single.bearerToken, 'sk-secret');
      // The failing save() override never wrote anything — the file on
      // disk is exactly what it was before load() ran.
      expect(await fileIn(tempDir).readAsString(), legacy);
    });
  });
}

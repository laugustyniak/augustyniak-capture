# Token Encryption at Rest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypt provider `bearerToken` values in `settings.json` with AES-256-GCM under a master key held in the OS keyring, with clean plaintext degradation when no keyring is available.

**Architecture:** New `TokenCipher` seam (domain interface, two impls) applied at the `SettingsRepository` boundary only — domain `toJson`/`fromJson` stay synchronous and untouched. In-memory `AppSettings` always holds plaintext; the on-disk value is `enc:v1:<base64(nonce|ciphertext|tag)>`. A token that fails to decrypt stays as its sealed blob in memory (never destroyed) and is filtered out at service-construction time via `ProviderProfile.usableBearerToken`.

**Tech Stack:** Flutter/Dart (SDK >=3.10.0), `flutter_secure_storage` (keyring: libsecret / Keychain / Keystore), `cryptography` (pure-Dart AES-GCM), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-08-04-token-encryption-design.md`
**Issue:** #30 — branch `feat/30-token-encryption`, worktree `.worktrees/feat-30-token-encryption`

## Global Constraints

- User-facing strings are English. Identifiers and comments are English.
- Persisted JSON stays backward compatible: every `fromJson` defaults absent fields; legacy plaintext tokens must keep loading.
- Atomic writes only: `.tmp` then `rename` (already implemented in `SettingsRepository.save` — do not change the write mechanics).
- Never destroy user data on failure: a token blob that cannot be decrypted is preserved on disk and in memory, never nulled or overwritten.
- Tests are pure-Dart (no Flutter bindings, no mocks packages, hand-written fakes) except the existing `test/widget/` suites.
- Conventional Commits: `<type>(<scope>): <subject>`, imperative, lowercase, ≤72 chars, footer `Refs #30`. No Claude/AI mentions anywhere.
- Run `flutter analyze && flutter test` before every commit — there is no CI; the pre-push hook is the only other gate.
- Lints in force: `avoid_print`, `prefer_final_locals` (declare locals `final`).
- The existing widget test `test/widget/models_tab_test.dart` asserts `find.textContaining('plaintext')` on the Models tab banner — the fallback (non-encrypted) banner copy MUST keep the word "plaintext".

---

### Task 0: Worktree and dependencies

**Files:**
- Modify: `pubspec.yaml`

**Interfaces:**
- Produces: worktree `.worktrees/feat-30-token-encryption` on branch `feat/30-token-encryption`; packages `flutter_secure_storage` and `cryptography` resolvable.

- [ ] **Step 1: Create the worktree and enable hooks**

```bash
cd /home/laugustyniak/github/tools/Audivoa-Core
git worktree add .worktrees/feat-30-token-encryption -b feat/30-token-encryption
cd .worktrees/feat-30-token-encryption
git config core.hooksPath .githooks
```

All later tasks run inside `.worktrees/feat-30-token-encryption`.

- [ ] **Step 2: Add dependencies**

In `pubspec.yaml`, after the `window_manager: ^0.5.2` line, add:

```yaml
  # Token encryption at rest: master key in the OS keyring, AES-GCM in Dart.
  # flutter_secure_storage needs libsecret-1-dev at build time on Linux.
  flutter_secure_storage: ^9.2.2
  cryptography: ^2.7.0
```

- [ ] **Step 3: Resolve and verify**

Run: `flutter pub get`
Expected: resolves without errors.
Run: `flutter analyze && flutter test`
Expected: clean — nothing uses the packages yet.

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add flutter_secure_storage and cryptography deps

Refs #30"
```

---

### Task 1: `TokenCipher` domain seam and `PlaintextTokenCipher`

**Files:**
- Create: `lib/features/settings/domain/token_cipher.dart`
- Create: `test/token_cipher_test.dart`

**Interfaces:**
- Produces (used by every later task):
  - `abstract class TokenCipher` with:
    - `static const String sealedPrefix = 'enc:v1:'`
    - `static bool isSealed(String value)`
    - `bool get encrypts`
    - `Future<void> ensureReady()`
    - `Future<String> seal(String token)` — identity when not encrypting or already sealed
    - `Future<String> unseal(String stored)` — identity when not sealed, not ready, or decryption fails (blob preservation)
  - `class PlaintextTokenCipher extends TokenCipher` — const, identity transforms, `encrypts == false`

- [ ] **Step 1: Write the failing tests**

Create `test/token_cipher_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/domain/token_cipher.dart';

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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/token_cipher_test.dart`
Expected: FAIL — `token_cipher.dart` does not exist.

- [ ] **Step 3: Implement**

Create `lib/features/settings/domain/token_cipher.dart`:

```dart
/// Encrypts and decrypts provider bearer tokens for storage in
/// `settings.json`.
///
/// Applied at the repository boundary only: in-memory [ProviderProfile]s hold
/// plaintext (the HTTP `Authorization` header needs it), the file on disk
/// holds `enc:v1:<base64(nonce|ciphertext|tag)>` when a cipher is active.
///
/// The contract every implementation keeps: **a value that cannot be
/// transformed passes through unchanged.** `seal` of an already-sealed value
/// is a no-op; `unseal` of a blob it cannot decrypt returns the blob — the
/// stored token is never destroyed by a missing or wrong key. Callers that
/// need a usable secret filter sealed values out via
/// `ProviderProfile.usableBearerToken`.
abstract class TokenCipher {
  const TokenCipher();

  /// On-disk marker for an encrypted value. Doubles as the format version:
  /// a future scheme change bumps `v1` and reads both.
  static const String sealedPrefix = 'enc:v1:';

  static bool isSealed(String value) => value.startsWith(sealedPrefix);

  /// True once this cipher can actually encrypt — drives the Models/Config
  /// tab copy and the load-time migration decision.
  bool get encrypts;

  /// Prepare the cipher (load or create the master key). Must never throw:
  /// a missing keyring degrades [encrypts] to false instead.
  Future<void> ensureReady();

  Future<String> seal(String token);

  Future<String> unseal(String stored);
}

/// Identity cipher: the fallback when no keyring is available, and the
/// default in tests. Keeps the pre-encryption behaviour byte for byte.
class PlaintextTokenCipher extends TokenCipher {
  const PlaintextTokenCipher();

  @override
  bool get encrypts => false;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<String> seal(String token) async => token;

  @override
  Future<String> unseal(String stored) async => stored;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/token_cipher_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze`
Expected: no issues.

```bash
git add lib/features/settings/domain/token_cipher.dart test/token_cipher_test.dart
git commit -m "feat(settings): add TokenCipher seam with plaintext default

Refs #30"
```

---

### Task 2: `AesGcmTokenCipher` and the key-store seam

**Files:**
- Create: `lib/features/settings/data/aes_gcm_token_cipher.dart`
- Create: `lib/features/settings/data/secure_storage_master_key_store.dart`
- Modify: `test/token_cipher_test.dart` (append a group)

**Interfaces:**
- Consumes: `TokenCipher`, `TokenCipher.sealedPrefix`, `TokenCipher.isSealed` from Task 1.
- Produces:
  - `abstract class MasterKeyStore { Future<String?> read(); Future<void> write(String value); }` (in `aes_gcm_token_cipher.dart`)
  - `class AesGcmTokenCipher extends TokenCipher` with constructor `AesGcmTokenCipher({required MasterKeyStore keyStore})`
  - `class SecureStorageMasterKeyStore implements MasterKeyStore` with constructor `SecureStorageMasterKeyStore()` (in `secure_storage_master_key_store.dart`)

- [ ] **Step 1: Write the failing tests**

Append to `test/token_cipher_test.dart` (add the import at the top of the file):

```dart
import 'package:audivoa_core/features/settings/data/aes_gcm_token_cipher.dart';
```

```dart
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
```

And the test group:

```dart
group('AesGcmTokenCipher', () {
  test('ensureReady generates and persists a master key', () async {
    final _MemoryKeyStore store = _MemoryKeyStore();
    final AesGcmTokenCipher cipher = AesGcmTokenCipher(keyStore: store);

    await cipher.ensureReady();

    expect(cipher.encrypts, isTrue);
    expect(store.value, isNotNull);
  });

  test('seal produces a prefixed blob and unseal round-trips it', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    await cipher.ensureReady();

    final String sealed = await cipher.seal('sk-secret');

    expect(TokenCipher.isSealed(sealed), isTrue);
    expect(sealed, isNot(contains('sk-secret')));
    expect(await cipher.unseal(sealed), 'sk-secret');
  });

  test('sealing twice yields different blobs (random nonce)', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    await cipher.ensureReady();

    expect(await cipher.seal('sk-secret'),
        isNot(await cipher.seal('sk-secret')));
  });

  test('seal of an already-sealed value is a no-op', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
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
    final AesGcmTokenCipher first =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    await first.ensureReady();
    final String sealed = await first.seal('sk-secret');

    // Different store, different generated key — a wiped keyring.
    final AesGcmTokenCipher second =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    await second.ensureReady();

    expect(await second.unseal(sealed), sealed);
  });

  test('unseal of a corrupt blob returns it unchanged', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    await cipher.ensureReady();

    expect(await cipher.unseal('enc:v1:not-base64!'), 'enc:v1:not-base64!');
  });

  test('a broken key store degrades to identity, never throws', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _BrokenKeyStore());
    await cipher.ensureReady();

    expect(cipher.encrypts, isFalse);
    expect(await cipher.seal('sk-secret'), 'sk-secret');
    expect(await cipher.unseal('enc:v1:blob'), 'enc:v1:blob');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/token_cipher_test.dart`
Expected: FAIL — `aes_gcm_token_cipher.dart` does not exist.

- [ ] **Step 3: Implement the cipher**

Create `lib/features/settings/data/aes_gcm_token_cipher.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/token_cipher.dart';

/// Where the 256-bit master key lives. One method pair so the OS keyring
/// (production) and an in-memory map (tests) are interchangeable — the same
/// seam shape as `LogArchive` and `MediaPicker`.
abstract class MasterKeyStore {
  Future<String?> read();

  Future<void> write(String value);
}

/// AES-256-GCM under a master key from [MasterKeyStore].
///
/// On-disk format: `enc:v1:` + base64 of the `cryptography` package's
/// SecretBox concatenation — 12-byte nonce, ciphertext, 16-byte MAC.
///
/// [ensureReady] loads or creates the key and never throws: any key-store
/// failure (no keyring daemon, locked Secret Service, missing plugin in a
/// test binding) leaves [encrypts] false and every transform an identity —
/// the same clean degradation as a missing `tesseract` binary.
class AesGcmTokenCipher extends TokenCipher {
  AesGcmTokenCipher({required MasterKeyStore keyStore}) : _keyStore = keyStore;

  static const int _keyLengthBytes = 32;
  static const int _macLengthBytes = 16;

  final MasterKeyStore _keyStore;
  final AesGcm _algorithm = AesGcm.with256bits();

  SecretKey? _key;
  bool _ready = false;
  Future<void>? _initializing;

  @override
  bool get encrypts => _ready;

  @override
  Future<void> ensureReady() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final String? stored = await _keyStore.read();
      if (stored != null) {
        final Uint8List bytes = base64Decode(stored);
        if (bytes.length == _keyLengthBytes) {
          _key = SecretKey(bytes);
          _ready = true;
          return;
        }
        // Wrong-sized value: something else owns this entry — do not
        // overwrite it, run without encryption.
        return;
      }

      final SecretKey generated = await _algorithm.newSecretKey();
      final List<int> keyBytes = await generated.extractBytes();
      await _keyStore.write(base64Encode(keyBytes));
      // Read back: proves the keyring persisted the key rather than merely
      // accepting the call. Tokens sealed under an unpersisted key would be
      // unreadable after the next launch.
      final String? verified = await _keyStore.read();
      if (verified == null) {
        return;
      }
      _key = SecretKey(base64Decode(verified));
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  @override
  Future<String> seal(String token) async {
    final SecretKey? key = _key;
    if (!_ready || key == null || TokenCipher.isSealed(token)) {
      return token;
    }
    final SecretBox box =
        await _algorithm.encrypt(utf8.encode(token), secretKey: key);
    return '${TokenCipher.sealedPrefix}${base64Encode(box.concatenation())}';
  }

  @override
  Future<String> unseal(String stored) async {
    final SecretKey? key = _key;
    if (!_ready || key == null || !TokenCipher.isSealed(stored)) {
      return stored;
    }
    try {
      final Uint8List bytes =
          base64Decode(stored.substring(TokenCipher.sealedPrefix.length));
      final SecretBox box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: AesGcm.defaultNonceLength,
        macLength: _macLengthBytes,
      );
      final List<int> clear = await _algorithm.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      // Wrong key or corrupt data. Hand the blob back untouched so it is
      // written back verbatim — the token recovers if the keyring returns.
      return stored;
    }
  }
}
```

- [ ] **Step 4: Implement the secure-storage key store**

Create `lib/features/settings/data/secure_storage_master_key_store.dart`:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'aes_gcm_token_cipher.dart';

/// [MasterKeyStore] backed by the OS keyring via `flutter_secure_storage`:
/// libsecret on Linux (needs `libsecret-1-dev` at build time and a running
/// keyring daemon), Keychain on iOS, Keystore-encrypted prefs on Android.
///
/// Deliberately untested: it is a two-line adapter over a platform channel,
/// and every failure mode is exercised through [AesGcmTokenCipher]'s
/// degradation path instead (`_BrokenKeyStore` in token_cipher_test.dart).
class SecureStorageMasterKeyStore implements MasterKeyStore {
  const SecureStorageMasterKeyStore();

  static const String _entry = 'token_master_key';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _entry);

  @override
  Future<void> write(String value) => _storage.write(key: _entry, value: value);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/token_cipher_test.dart`
Expected: PASS (all groups).

- [ ] **Step 6: Analyze and commit**

Run: `flutter analyze`
Expected: no issues.

```bash
git add lib/features/settings/data/aes_gcm_token_cipher.dart \
        lib/features/settings/data/secure_storage_master_key_store.dart \
        test/token_cipher_test.dart
git commit -m "feat(settings): add AES-GCM token cipher with keyring key store

Refs #30"
```

---

### Task 3: `ProviderProfile.usableBearerToken`

**Files:**
- Modify: `lib/features/settings/domain/provider_profile.dart`
- Create: `test/settings_encryption_test.dart`

**Interfaces:**
- Consumes: `TokenCipher.isSealed` from Task 1.
- Produces: `String? get usableBearerToken` on `ProviderProfile` — the token if usable, null when blank or still sealed. All three service factories (`toService`, `toEnrichmentService`, `toOcrService`) now pass `usableBearerToken` instead of `_blankToNull(bearerToken)`.

- [ ] **Step 1: Write the failing tests**

Create `test/settings_encryption_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:audivoa_core/features/settings/domain/provider_profile.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/settings_encryption_test.dart`
Expected: FAIL — `usableBearerToken` is not defined.

- [ ] **Step 3: Implement**

In `lib/features/settings/domain/provider_profile.dart`:

Add the import (alphabetical among the relative imports):

```dart
import 'token_cipher.dart';
```

Replace the `bearerToken` doc comment (currently "Stored in plaintext … Encryption is a later phase."):

```dart
  /// Encrypted at rest in `settings.json` when the OS keyring is available
  /// (see `TokenCipher`); plaintext otherwise, which the Config tab surfaces.
  /// In memory this is normally the plaintext value, but after a failed
  /// decrypt (keyring wiped or locked) it holds the sealed `enc:v1:` blob so
  /// the stored token is never destroyed — [usableBearerToken] filters that
  /// case out for request headers.
  final String? bearerToken;
```

Add the getter directly below `hasEndpoint`:

```dart
  /// The token a request may actually send: null when unset, blank, or still
  /// sealed because decryption failed. A sealed blob must never leak into an
  /// `Authorization` header.
  String? get usableBearerToken {
    final String? token = _blankToNull(bearerToken);
    if (token == null || TokenCipher.isSealed(token)) return null;
    return token;
  }
```

In `toService()`, `toEnrichmentService()`, and `toOcrService()`, replace each `bearerToken: _blankToNull(bearerToken),` with:

```dart
      bearerToken: usableBearerToken,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/settings_encryption_test.dart test/settings_test.dart`
Expected: PASS — including the untouched existing settings suite.

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze`
Expected: no issues.

```bash
git add lib/features/settings/domain/provider_profile.dart test/settings_encryption_test.dart
git commit -m "feat(settings): filter sealed tokens out of request headers

Refs #30"
```

---

### Task 4: Repository seal/unseal and load-time migration

**Files:**
- Modify: `lib/features/settings/data/settings_repository.dart`
- Modify: `test/settings_encryption_test.dart` (append groups)

**Interfaces:**
- Consumes: `TokenCipher`, `PlaintextTokenCipher` (Task 1), `AesGcmTokenCipher`, `MasterKeyStore` (Task 2).
- Produces:
  - `SettingsRepository({TokenCipher? cipher})` — defaults to `const PlaintextTokenCipher()`, so every existing caller and test fake keeps compiling unchanged.
  - `bool get encryptsTokens` on `SettingsRepository`.
  - `Future<AppSettings> sealTokens(AppSettings settings)` and `Future<AppSettings> unsealTokens(AppSettings settings)` — public so they are testable without file IO.
  - `load()` unseals and migrates; `save()` seals.

- [ ] **Step 1: Write the failing tests**

Append to `test/settings_encryption_test.dart`. Add imports at the top:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:audivoa_core/features/settings/data/aes_gcm_token_cipher.dart';
import 'package:audivoa_core/features/settings/data/settings_repository.dart';
import 'package:audivoa_core/features/settings/domain/app_settings.dart';
import 'package:audivoa_core/features/settings/domain/token_cipher.dart';
```

Add the fakes (below `main`'s closing brace or above `main`, matching the file's layout):

```dart
/// Same convention as `_FakeSettingsRepository` in settings_test.dart, but
/// keeps the real load/save/seal logic and only redirects the file: the one
/// path_provider touchpoint is `settingsFile()`, so overriding it lets the
/// full pipeline — atomic write included — run against a temp file.
class _TempFileSettingsRepository extends SettingsRepository {
  _TempFileSettingsRepository(this.file, {super.cipher});

  final File file;

  @override
  Future<File> settingsFile() async => file;
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
```

Add the test groups inside `main()`:

```dart
group('SettingsRepository token encryption', () {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('audivoa_settings_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File fileIn(Directory dir) => File('${dir.path}/settings.json');

  test('save seals the token; the plaintext never reaches disk', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    final _TempFileSettingsRepository repository =
        _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

    await repository.save(_settingsWithToken('sk-secret'));

    final String raw = await fileIn(tempDir).readAsString();
    expect(raw, isNot(contains('sk-secret')));
    expect(raw, contains(TokenCipher.sealedPrefix));
  });

  test('load returns the plaintext token again (round trip)', () async {
    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    final _TempFileSettingsRepository repository =
        _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

    await repository.save(_settingsWithToken('sk-secret'));
    final AppSettings? loaded = await repository.load();

    expect(loaded!.profiles.single.bearerToken, 'sk-secret');
  });

  test('a legacy plaintext file is migrated on load', () async {
    // Written by a build that predates encryption.
    await fileIn(tempDir).writeAsString(
        jsonEncode(_settingsWithToken('sk-secret').toJson()));

    final AesGcmTokenCipher cipher =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    final _TempFileSettingsRepository repository =
        _TempFileSettingsRepository(fileIn(tempDir), cipher: cipher);

    final AppSettings? loaded = await repository.load();

    expect(loaded!.profiles.single.bearerToken, 'sk-secret');
    final String raw = await fileIn(tempDir).readAsString();
    expect(raw, isNot(contains('sk-secret')));
    expect(raw, contains(TokenCipher.sealedPrefix));
  });

  test('without a cipher the file stays plaintext and untouched', () async {
    final String legacy =
        jsonEncode(_settingsWithToken('sk-secret').toJson());
    await fileIn(tempDir).writeAsString(legacy);

    final _TempFileSettingsRepository repository =
        _TempFileSettingsRepository(fileIn(tempDir));

    final AppSettings? loaded = await repository.load();

    expect(loaded!.profiles.single.bearerToken, 'sk-secret');
    expect(await fileIn(tempDir).readAsString(), legacy);
    expect(repository.encryptsTokens, isFalse);
  });

  test('a blob sealed under a lost key survives load and re-save', () async {
    final AesGcmTokenCipher original =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    final _TempFileSettingsRepository writer =
        _TempFileSettingsRepository(fileIn(tempDir), cipher: original);
    await writer.save(_settingsWithToken('sk-secret'));
    final String sealedOnDisk = await fileIn(tempDir).readAsString();

    // A wiped keyring: a fresh store generates a different key.
    final AesGcmTokenCipher wrongKey =
        AesGcmTokenCipher(keyStore: _MemoryKeyStore());
    final _TempFileSettingsRepository reader =
        _TempFileSettingsRepository(fileIn(tempDir), cipher: wrongKey);

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
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/settings_encryption_test.dart`
Expected: FAIL — `SettingsRepository` has no `cipher` parameter.

- [ ] **Step 3: Implement**

Rewrite `lib/features/settings/data/settings_repository.dart` as:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/app_settings.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';

/// Persists `settings.json` next to `recordings.json`, using the same atomic
/// write (`.tmp` then `rename`) so a crash mid-write cannot truncate settings.
///
/// Bearer tokens cross this boundary through [TokenCipher]: sealed on the way
/// to disk, unsealed on the way back, so the in-memory [AppSettings] always
/// holds what an `Authorization` header needs. The default cipher is the
/// plaintext identity — existing tests and a keyring-less runtime behave
/// exactly as before.
class SettingsRepository {
  SettingsRepository({TokenCipher? cipher})
      : _cipher = cipher ?? const PlaintextTokenCipher();

  final TokenCipher _cipher;

  /// Whether tokens written by [save] are actually encrypted — drives the
  /// Models/Config tab copy.
  bool get encryptsTokens => _cipher.encrypts;

  Future<Directory> _directory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory =
        Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> settingsFile() async {
    final Directory directory = await _directory();
    return File(p.join(directory.path, 'settings.json'));
  }

  Future<AppSettings?> load() async {
    await _cipher.ensureReady();

    final File file = await settingsFile();
    if (!await file.exists()) {
      return null;
    }

    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return null;
    }

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final AppSettings stored = AppSettings.fromJson(decoded);
    final AppSettings settings = await unsealTokens(stored);

    // One-time migration: a file holding any plaintext token is rewritten
    // sealed as soon as a working cipher sees it. With no cipher the file is
    // deliberately left untouched and the migration retries next launch.
    if (_cipher.encrypts && _hasPlaintextToken(stored)) {
      await save(settings);
    }
    return settings;
  }

  Future<void> save(AppSettings settings) async {
    await _cipher.ensureReady();
    final AppSettings sealed = await sealTokens(settings);

    final File file = await settingsFile();
    final String payload =
        const JsonEncoder.withIndent('  ').convert(sealed.toJson());

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }

  /// Seal every profile token for disk. Public (rather than folded into
  /// [save]) so the transform is testable without file IO. An already-sealed
  /// value — an unrecoverable blob carried in memory — passes through
  /// verbatim: re-sealing it would wrap ciphertext in ciphertext and lose the
  /// original token forever.
  Future<AppSettings> sealTokens(AppSettings settings) =>
      _mapTokens(settings, _cipher.seal);

  /// Unseal every profile token after parse. A blob the cipher cannot decrypt
  /// comes back unchanged — see [TokenCipher.unseal].
  Future<AppSettings> unsealTokens(AppSettings settings) =>
      _mapTokens(settings, _cipher.unseal);

  Future<AppSettings> _mapTokens(
    AppSettings settings,
    Future<String> Function(String value) transform,
  ) async {
    bool changed = false;
    final List<ProviderProfile> profiles = <ProviderProfile>[];
    for (final ProviderProfile profile in settings.profiles) {
      final String? token = profile.bearerToken;
      if (token == null) {
        profiles.add(profile);
        continue;
      }
      final String value = await transform(token);
      if (value == token) {
        profiles.add(profile);
      } else {
        changed = true;
        profiles.add(profile.copyWith(bearerToken: value));
      }
    }
    return changed ? settings.copyWith(profiles: profiles) : settings;
  }

  static bool _hasPlaintextToken(AppSettings settings) =>
      settings.profiles.any((ProviderProfile profile) =>
          profile.bearerToken != null &&
          !TokenCipher.isSealed(profile.bearerToken!));
}
```

- [ ] **Step 4: Run the full test suite**

Run: `flutter test`
Expected: PASS — the whole suite, including `settings_test.dart` (its `_FakeSettingsRepository` extends this class with the new optional parameter defaulted) and the widget suites.

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze`
Expected: no issues.

```bash
git add lib/features/settings/data/settings_repository.dart test/settings_encryption_test.dart
git commit -m "feat(settings): seal tokens at the repository boundary

Encrypt on save, decrypt on load, and migrate a legacy plaintext
settings.json the first time a working cipher sees it. A blob that no
longer decrypts is carried and written back verbatim so a wiped keyring
never destroys the stored token.

Refs #30"
```

---

### Task 5: Wiring and UI copy

**Files:**
- Modify: `lib/features/settings/presentation/settings_controller.dart` (add one getter)
- Modify: `lib/features/recordings/presentation/recordings_page.dart:69` (construct the real cipher)
- Modify: `lib/features/settings/presentation/config_tab.dart:140-147` (TOKEN row)
- Modify: `lib/features/settings/presentation/models_tab.dart:38-58` (banner)

**Interfaces:**
- Consumes: `SettingsRepository.encryptsTokens` (Task 4), `AesGcmTokenCipher`/`SecureStorageMasterKeyStore` (Task 2), `TokenCipher.isSealed` (Task 1).
- Produces: `bool get tokenEncryptionActive` on `SettingsController` (used by both tabs).

- [ ] **Step 1: Controller getter**

In `lib/features/settings/presentation/settings_controller.dart`, below the `String? get error` line, add:

```dart
  /// Whether tokens written to disk are actually encrypted. False on the
  /// plaintext fallback (no keyring) so the Models/Config tabs can say so.
  bool get tokenEncryptionActive => _repository.encryptsTokens;
```

- [ ] **Step 2: Shell wiring**

In `lib/features/recordings/presentation/recordings_page.dart`, add imports (match the existing relative-import style of that file):

```dart
import '../../settings/data/aes_gcm_token_cipher.dart';
import '../../settings/data/secure_storage_master_key_store.dart';
import '../../settings/data/settings_repository.dart';
```

Replace line 69 `settings = SettingsController();` with:

```dart
    settings = SettingsController(
      repository: SettingsRepository(
        // Real keyring-backed cipher on every platform; ensureReady degrades
        // to the plaintext behaviour when no keyring answers (headless Linux,
        // locked Secret Service, test bindings).
        cipher: AesGcmTokenCipher(keyStore: const SecureStorageMasterKeyStore()),
      ),
    );
```

- [ ] **Step 3: Config tab TOKEN row**

In `lib/features/settings/presentation/config_tab.dart`, add the import:

```dart
import '../domain/token_cipher.dart';
```

(also `import '../domain/provider_profile.dart';` if not already imported — check the file head.)

Replace the TOKEN `InfoRow` (lines 140–147):

```dart
                InfoRow(
                  label: 'TOKEN',
                  value: _tokenStatus(active, controller.tokenEncryptionActive),
                  valueColor:
                      _tokenColor(active, controller.tokenEncryptionActive),
                ),
```

Add at the bottom of the file (top-level, private):

```dart
String _tokenStatus(ProviderProfile? active, bool encrypted) {
  final String? token = active?.bearerToken;
  if (token == null) return 'none';
  if (TokenCipher.isSealed(token)) {
    return '•••• unreadable — keyring unavailable';
  }
  return encrypted ? '•••• encrypted at rest' : '•••• set (plaintext on disk)';
}

Color _tokenColor(ProviderProfile? active, bool encrypted) {
  final String? token = active?.bearerToken;
  if (token == null) return Console.mutedSoft;
  if (TokenCipher.isSealed(token)) return Console.amber;
  return encrypted ? Console.text : Console.amber;
}
```

(`Color` needs `package:flutter/material.dart`, already imported by the tab. Verify the local variable holding the active profile is named `active` at line ~124; adjust to the actual name if it differs.)

- [ ] **Step 4: Models tab banner**

In `lib/features/settings/presentation/models_tab.dart`, replace the `const ConsoleCard(...)` banner (lines 38–58) with a non-const conditional version:

```dart
          ConsoleCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: controller.tokenEncryptionActive
                      ? Console.cyan
                      : Console.amber,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    controller.tokenEncryptionActive
                        ? 'Tokens are encrypted at rest (AES-256-GCM). The '
                            'key lives in your system keyring, never in '
                            'settings.json.'
                        : 'Tokens are stored as plaintext in the app '
                            'documents directory (settings.json) — system '
                            'keyring unavailable.',
                    style: const TextStyle(
                      color: Console.mutedSoft,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
```

The fallback copy keeps the word "plaintext" — `test/widget/models_tab_test.dart:129` asserts `find.textContaining('plaintext')`, and the widget harness runs with the default `PlaintextTokenCipher`, so the fallback branch is the one rendered in tests.

- [ ] **Step 5: Run everything**

Run: `flutter analyze && flutter test`
Expected: both clean, including `test/widget/models_tab_test.dart`.

- [ ] **Step 6: Commit**

```bash
git add lib/features/settings/presentation/settings_controller.dart \
        lib/features/recordings/presentation/recordings_page.dart \
        lib/features/settings/presentation/config_tab.dart \
        lib/features/settings/presentation/models_tab.dart
git commit -m "feat(settings): wire keyring cipher and surface encryption state

Refs #30"
```

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: CLAUDE.md**

Two edits:

1. In the **Commands** section, next to the `keybinder-3.0` note, add:

> **Linux builds also need `libsecret-1-dev`** — `flutter_secure_storage` links against libsecret for the token-encryption master key. Without it `flutter build linux` fails at build time. At runtime a keyring daemon (gnome-keyring) must be running and unlocked, otherwise token encryption degrades to plaintext with a visible Config-tab warning:
>
> ```bash
> sudo apt-get install libsecret-1-dev
> ```

2. In the **Settings** paragraph of the Architecture section, replace the sentence
   `Tokens are stored in plaintext — surfaced as a warning in the UI, encryption is a later phase.`
   with:

> Tokens are encrypted at rest: AES-256-GCM under a master key in the OS keyring (`TokenCipher` seam — `AesGcmTokenCipher` + `SecureStorageMasterKeyStore`, applied at the `SettingsRepository` boundary; in-memory settings always hold plaintext). On-disk format `enc:v1:<base64(nonce|ciphertext|tag)>`; legacy plaintext tokens auto-migrate on the first load with a working keyring. No keyring → clean plaintext fallback, surfaced in the Models/Config tabs. A blob that no longer decrypts (wiped keyring) is preserved verbatim — `usableBearerToken` keeps it out of request headers, and it recovers when the keyring returns.

- [ ] **Step 2: README.md**

Find the Linux prerequisites (grep for `keybinder`) and add `libsecret-1-dev` alongside, with one sentence: tokens are encrypted with a key in the system keyring; without a keyring the app stores them plaintext and says so in the Config tab.

- [ ] **Step 3: Verify and commit**

Run: `flutter analyze && flutter test`
Expected: clean.

```bash
git add CLAUDE.md README.md
git commit -m "docs: describe token encryption at rest and libsecret dependency

Refs #30"
```

---

### Task 7: Final verification and integration

- [ ] **Step 1: Full local gate**

Run in the worktree: `flutter analyze && flutter test`
Expected: zero analyzer issues, all tests green.

- [ ] **Step 2: Manual smoke test (Linux desktop)**

```bash
flutter run -d linux
```

- Models tab → banner reads "encrypted at rest" (keyring present) or the plaintext fallback.
- Add/edit a profile with a token → quit → `cat ~/Documents/recordings/settings.json` (or the app-docs path) → `bearerToken` shows `enc:v1:…`, not the token.
- Relaunch → transcription still works (token decrypts).

- [ ] **Step 3: Code review before PR**

Dispatch a code-review subagent on `git diff main...feat/30-token-encryption` (per repo convention: never open a PR on an unreviewed diff). Fix findings, commit.

- [ ] **Step 4: Integrate**

Use superpowers:finishing-a-development-branch. Merge per repo convention:

```bash
git switch main && git pull --ff-only
git merge --no-ff feat/30-token-encryption -m "Merge branch 'feat/30-token-encryption' (#30)"
git push
git worktree remove .worktrees/feat-30-token-encryption
```

(Or PR: `gh pr create` from the branch, body references `Closes #30`, merge with `gh pr merge --merge --delete-branch`.)

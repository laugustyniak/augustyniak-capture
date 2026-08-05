import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'aes_gcm_token_cipher.dart';

/// [MasterKeyStore] backed by the OS keyring via `flutter_secure_storage`:
/// libsecret on Linux (needs `libsecret-1-dev` at build time and a running
/// keyring daemon), Keychain on macOS/iOS, Keystore-encrypted prefs on Android.
///
/// Deliberately untested beyond [macOsOptions] below: it is a thin adapter over
/// a platform channel, and every failure mode is exercised through
/// [AesGcmTokenCipher]'s degradation path instead (`_BrokenKeyStore` in
/// token_cipher_test.dart).
class SecureStorageMasterKeyStore implements MasterKeyStore {
  const SecureStorageMasterKeyStore();

  static const String _entry = 'token_master_key';

  /// **`useDataProtectionKeyChain` must stay false, and it is the difference
  /// between token encryption working on macOS and silently never running.**
  ///
  /// The plugin defaults it to `true`, which routes every Keychain call at the
  /// *data protection* keychain. That keychain identifies a caller by its
  /// `keychain-access-groups` entitlement, and that entitlement is only valid
  /// under a Team-ID signature — this app is **ad-hoc signed**
  /// (`CODE_SIGN_IDENTITY = "-"`, see CLAUDE.md), so it has no such identity and
  /// `SecItemAdd` answers `-34018 errSecMissingEntitlement` on every launch.
  ///
  /// The consequence was invisible, because it degrades exactly the way a
  /// missing keyring daemon does: [AesGcmTokenCipher] swallows the
  /// `PlatformException`, `encrypts` stays false, `seal` becomes the identity,
  /// and the provider tokens are written to `settings.json` in plaintext. The
  /// only visible trace was one amber line in the Config tab reading
  /// *"plaintext on disk"*, which is also what a headless Linux box says.
  ///
  /// `false` selects the classic file-based login keychain, which a
  /// **non-sandboxed** app reaches with no entitlement at all — and the sandbox
  /// is off here for unrelated but equally load-bearing reasons. Turning the
  /// sandbox back on (a Mac App Store prerequisite) means revisiting this: a
  /// sandboxed app needs the data protection keychain, and therefore a real
  /// signing identity.
  ///
  /// The cost of the classic keychain is that its ACL names the app by code
  /// signature, and an ad-hoc signature changes on every rebuild — so a rebuilt
  /// binary can prompt *"Augustyniak Capture wants to use your keychain"*, the
  /// same way a rebuild can re-prompt for microphone consent. Answering "Always
  /// Allow" once per build settles it; denying it degrades to the plaintext
  /// fallback rather than failing a capture.
  static const MacOsOptions macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: false,
  );

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    mOptions: macOsOptions,
  );

  @override
  Future<String?> read() => _storage.read(key: _entry);

  @override
  Future<void> write(String value) => _storage.write(key: _entry, value: value);
}

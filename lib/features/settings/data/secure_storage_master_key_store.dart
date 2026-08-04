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

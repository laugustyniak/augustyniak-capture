import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/security/app_secure_storage.dart';

abstract interface class SecureValueStore {
  Future<bool> containsKey(String key);

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureValueStore implements SecureValueStore {
  const FlutterSecureValueStore({
    FlutterSecureStorage storage = AppSecureStorage.instance,
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Stores both the Supabase session and PKCE verifier in the OS keyring.
///
/// Supabase defaults both to Shared Preferences. This adapter fails closed: a
/// missing or locked keyring produces an in-memory session, never a plaintext
/// fallback on disk, and never prevents local capture from starting.
class SecureAuthStorage extends LocalStorage implements GotrueAsyncStorage {
  SecureAuthStorage({SecureValueStore? store})
    : _store = store ?? const FlutterSecureValueStore();

  static const String sessionKey = 'ai.augustyniak.capture.supabase.session';
  static const String pkceKeyPrefix = 'ai.augustyniak.capture.supabase.pkce.';

  final SecureValueStore _store;
  String? _unavailableReason;

  bool get available => _unavailableReason == null;
  String? get unavailableReason => _unavailableReason;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() =>
      _read(() => _store.containsKey(sessionKey), false);

  @override
  Future<String?> accessToken() => _read(() => _store.read(sessionKey), null);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _write(() => _store.write(sessionKey, persistSessionString));

  @override
  Future<void> removePersistedSession() =>
      _write(() => _store.delete(sessionKey));

  @override
  Future<String?> getItem({required String key}) =>
      _read(() => _store.read('$pkceKeyPrefix$key'), null);

  @override
  Future<void> setItem({required String key, required String value}) =>
      _write(() => _store.write('$pkceKeyPrefix$key', value));

  @override
  Future<void> removeItem({required String key}) =>
      _write(() => _store.delete('$pkceKeyPrefix$key'));

  Future<T> _read<T>(Future<T> Function() operation, T fallback) async {
    try {
      return await operation();
    } catch (_) {
      _markUnavailable();
      return fallback;
    }
  }

  Future<void> _write(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      _markUnavailable();
    }
  }

  void _markUnavailable() {
    _unavailableReason ??= 'OS secure session storage is unavailable.';
  }
}

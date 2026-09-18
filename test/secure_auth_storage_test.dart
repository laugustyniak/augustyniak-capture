import 'package:augustyniak_capture/features/auth/data/secure_auth_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SecureAuthStorage', () {
    test(
      'persists and removes the Supabase session in the secure store',
      () async {
        final _MemorySecureValueStore values = _MemorySecureValueStore();
        final SecureAuthStorage storage = SecureAuthStorage(store: values);

        await storage.initialize();
        expect(await storage.hasAccessToken(), isFalse);

        await storage.persistSession('refresh-session');

        expect(await storage.hasAccessToken(), isTrue);
        expect(await storage.accessToken(), 'refresh-session');
        expect(values.values.keys, contains(SecureAuthStorage.sessionKey));

        await storage.removePersistedSession();
        expect(await storage.hasAccessToken(), isFalse);
      },
    );

    test('keeps the PKCE verifier in the secure store too', () async {
      final _MemorySecureValueStore values = _MemorySecureValueStore();
      final SecureAuthStorage storage = SecureAuthStorage(store: values);

      await storage.setItem(key: 'pkce-code-verifier', value: 'verifier');

      expect(await storage.getItem(key: 'pkce-code-verifier'), 'verifier');
      expect(
        values.values.keys.single,
        '${SecureAuthStorage.pkceKeyPrefix}pkce-code-verifier',
      );

      await storage.removeItem(key: 'pkce-code-verifier');
      expect(await storage.getItem(key: 'pkce-code-verifier'), isNull);
    });

    test(
      'fails closed without replacing keyring storage with plaintext',
      () async {
        final SecureAuthStorage storage = SecureAuthStorage(
          store: _ThrowingSecureValueStore(),
        );

        expect(await storage.hasAccessToken(), isFalse);
        expect(await storage.accessToken(), isNull);
        await storage.persistSession('must-not-leak');

        expect(storage.available, isFalse);
        expect(storage.unavailableReason, contains('secure session storage'));
      },
    );
  });
}

class _MemorySecureValueStore implements SecureValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _ThrowingSecureValueStore implements SecureValueStore {
  Never _fail() => throw StateError('secret platform details');

  @override
  Future<bool> containsKey(String key) async => _fail();

  @override
  Future<void> delete(String key) async => _fail();

  @override
  Future<String?> read(String key) async => _fail();

  @override
  Future<void> write(String key, String value) async => _fail();
}

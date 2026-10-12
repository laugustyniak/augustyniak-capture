import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../auth/data/secure_auth_storage.dart';
import '../../logs/domain/log_event.dart';
import '../domain/e2ee_cipher.dart';
import '../domain/media_sync.dart';
import '../domain/sync_transport.dart';
import 'encrypted_media_store.dart';
import 'encrypted_sync_transport.dart';

class InvalidE2eePassphraseException implements Exception {
  const InvalidE2eePassphraseException([this.message = 'Invalid E2EE passphrase']);
  final String message;

  @override
  String toString() => 'InvalidE2eePassphraseException: $message';
}

/// What the server keeps about a user's key: enough for a second device to
/// re-derive it from the passphrase, and nothing that opens an envelope.
/// [iterations] travels with the salt so the KDF cost can be raised for new
/// keys without orphaning the ones already derived — see
/// [E2eeKeyDerivation].
class E2eePublicParams {
  const E2eePublicParams({
    required this.saltBase64,
    required this.keyCheckHash,
    required this.iterations,
    this.algorithm = 'pbkdf2_sha256',
  });

  final String saltBase64;
  final String keyCheckHash;
  final int iterations;
  final String algorithm;
}

/// Service managing the client-side lifecycle of the E2EE Master Encryption Key (MEK).
///
/// Keys are stored in the OS keyring via [SecureValueStore] or held in memory.
/// Neither the user's passphrase nor the unencrypted MEK is ever sent to the server.
///
/// Holds the device's end-to-end encryption key and decides, per sync run,
/// whether the transport and media store it is handed get sealed. The key
/// belongs to one identity: [followIdentity] drops it the moment the
/// signed-in user changes and restores the new user's key from the keyring,
/// so a key can never seal rows under another owner's id.
///
/// A [ChangeNotifier] so the Queue can say which of the two it is: notifies
/// whenever [cipher] or [hasIdentity] changes.
class E2eeService extends ChangeNotifier {
  E2eeService({
    SecureValueStore? secureStore,
    E2eeKeyDerivation? kdf,
    this.keyringTimeout = defaultKeyringTimeout,
  })  : _secureStore = secureStore ?? const FlutterSecureValueStore(),
        _kdf = kdf ?? E2eeKeyDerivation();

  final SecureValueStore _secureStore;
  final E2eeKeyDerivation _kdf;

  /// A keyring that never answers (a locked prompt) must not refuse every
  /// run for the rest of the session; past this a read counts as "no key".
  final Duration keyringTimeout;
  static const Duration defaultKeyringTimeout = Duration(seconds: 10);

  E2eeCipher? _cipher;
  String? _userId;
  int _generation = 0;
  Future<void>? _restoring;
  bool _disposed = false;

  bool get isUnlocked => _cipher != null;
  E2eeCipher? get cipher => _cipher;

  /// Whether [followIdentity] last saw a signed-in user. With an identity
  /// and no key, every sync run leaves in plaintext — the state the Queue
  /// has to show.
  bool get hasIdentity => _userId != null;

  /// Whether the followed user's key is still being read from the keyring.
  /// Runs are refused meanwhile (see [wrapTransport]), so the Queue has no
  /// plaintext to warn about yet.
  bool get isRestoring => _restoring != null;

  void _setCipher(E2eeCipher? cipher) {
    if (_disposed || identical(cipher, _cipher)) return;
    _cipher = cipher;
    notifyListeners();
  }

  /// Binds the held key to the signed-in user. Called by the app shell on
  /// every auth change with the current user id, or null when signed out.
  ///
  /// Any key held is dropped **before** the new user's is looked up, so a
  /// user without a stored key never inherits the previous user's; and a
  /// restore that completes after the identity moved on is discarded, so a
  /// fast sign-out cannot leave a key held while signed out. Repeat calls
  /// with the same id are no-ops: the auth controller notifies on busy and
  /// error changes too, and those must not re-read the keyring or churn the
  /// cipher under a run.
  Future<void> followIdentity(String? userId) {
    if (userId == _userId) return _restoring ?? Future<void>.value();
    final int generation = ++_generation;
    _userId = userId;
    _cipher = null;
    _restoring = null;
    if (!_disposed) notifyListeners();
    if (userId == null) return Future<void>.value();
    final Future<void> restore = _readKeyring(userId).then((E2eeCipher? restored) {
      if (generation != _generation) return;
      _restoring = null;
      if (!_disposed) notifyListeners(); // `isRestoring` changed
      _setCipher(restored);
    });
    return _restoring = restore;
  }

  /// Binds a key being set up, unlocked or restored to [userId]: refused for
  /// a user other than the one followed, and ends any restore in flight so
  /// it cannot land on top of the newer key.
  void _claim(String userId) {
    if (_userId != null && _userId != userId) {
      throw StateError('E2EE key for $userId while following $_userId');
    }
    _userId = userId;
    _generation++;
    _restoring = null;
  }

  /// Refuses to hand out a transport or store for a run that is not the
  /// followed user's, or that starts while that user's key is still being
  /// read from the keyring. Either would let a run leave under the wrong
  /// key or in plaintext while a key exists; the controller turns the error
  /// into a failed slot and the next run tries again.
  void _checkOwner(String ownerId) {
    if (ownerId != _userId) {
      throw StateError('sync skipped: signed-in user changed');
    }
    if (_restoring != null) {
      throw StateError('sync skipped: encryption key still loading');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  /// The transport the engine runs over: [inner] sealed under the current
  /// key, or [inner] itself while no key is held. Called by the resolver on
  /// every run, so a key that arrives later applies to the next run and
  /// never redirects one in flight. Without a key rows leave in plaintext —
  /// the Queue's sync status says so (`NOT ENCRYPTED`); nothing here hides it.
  SyncTransport wrapTransport(
    SyncTransport inner, {
    required String ownerId,
    LogSink log = const NoopLogSink(),
  }) {
    _checkOwner(ownerId);
    final E2eeCipher? cipher = _cipher;
    if (cipher == null) {
      // The launch sync and the edit-debounce sync show no panel, so this
      // line is the one trace of a plaintext run those paths leave.
      log.log(
        'Sync: no encryption key on this device; rows leave in plaintext',
        level: LogLevel.warn,
      );
      return inner;
    }
    return EncryptedSyncTransport(
      inner: inner,
      cipher: cipher,
      ownerId: ownerId,
      log: log,
    );
  }

  /// The media store's counterpart of [wrapTransport].
  MediaObjectStore wrapMediaStore(
    MediaObjectStore inner, {
    required String ownerId,
  }) {
    _checkOwner(ownerId);
    final E2eeCipher? cipher = _cipher;
    if (cipher == null) return inner;
    return EncryptedMediaStore(inner: inner, cipher: cipher, ownerId: ownerId);
  }

  static String _keyStoreKey(String userId) =>
      'ai.augustyniak.capture.e2ee.mek.$userId';

  /// Sets up a new passphrase, generates a fresh salt, derives the 256-bit MEK,
  /// persists the MEK in the local OS keyring, and returns the public KDF parameters.
  Future<E2eePublicParams> setupPassphrase({
    required String userId,
    required String passphrase,
  }) async {
    _claim(userId);
    final List<int> salt = _kdf.generateSalt();
    final SecretKey key = await _kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
    );
    final String keyCheckHash = await _kdf.computeKeyCheckHash(
      key: key,
      salt: salt,
    );

    final List<int> keyBytes = await key.extractBytes();
    await _secureStore.write(
      _keyStoreKey(userId),
      base64Encode(keyBytes),
    );

    _setCipher(await E2eeCipher.forMasterKey(key));

    return E2eePublicParams(
      saltBase64: base64Encode(salt),
      keyCheckHash: keyCheckHash,
      iterations: _kdf.iterations,
    );
  }

  /// Verifies a passphrase against the remote salt and keyCheckHash, derives the MEK,
  /// saves it to the local OS keyring, and activates encryption.
  /// Throws [InvalidE2eePassphraseException] if passphrase is incorrect.
  ///
  /// [iterations] is the count the key was set up with, read from the same
  /// server row as the salt — not this build's default, which may since
  /// have been raised.
  Future<bool> unlockWithPassphrase({
    required String userId,
    required String passphrase,
    required String saltBase64,
    required String expectedCheckHash,
    required int iterations,
  }) async {
    _claim(userId);
    if (!expectedCheckHash.startsWith(E2eeKeyDerivation.keyCheckPrefix)) {
      // A pre-#298 row stored `sha256(key || salt)`; nothing derives that
      // any more, and reporting it as a wrong passphrase would send the user
      // retyping a passphrase that is right.
      throw const InvalidE2eePassphraseException(
        'This key was set up by an older build and cannot be verified; '
        'set up the passphrase again',
      );
    }
    final Uint8List salt = base64Decode(saltBase64);
    final E2eeKeyDerivation kdf = iterations == _kdf.iterations
        ? _kdf
        : E2eeKeyDerivation(iterations: iterations);
    final SecretKey key = await kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
    );
    final String actualHash = await kdf.computeKeyCheckHash(
      key: key,
      salt: salt,
    );

    if (actualHash != expectedCheckHash) {
      throw const InvalidE2eePassphraseException();
    }

    final List<int> keyBytes = await key.extractBytes();
    await _secureStore.write(
      _keyStoreKey(userId),
      base64Encode(keyBytes),
    );

    _setCipher(await E2eeCipher.forMasterKey(key));
    return true;
  }

  /// Attempts to restore an already unlocked MEK from the local keyring on app launch.
  Future<bool> tryRestoreFromKeyring({required String userId}) async {
    _claim(userId);
    final int generation = _generation;
    final E2eeCipher? restored = await _readKeyring(userId);
    if (restored == null || generation != _generation) return false;
    _setCipher(restored);
    return true;
  }

  /// The data-key cipher for the key stored under [userId], or null when
  /// there is none, it is malformed, or the keyring is unavailable.
  Future<E2eeCipher?> _readKeyring(String userId) async {
    try {
      final String? stored = await _secureStore
          .read(_keyStoreKey(userId))
          .timeout(keyringTimeout, onTimeout: () => null);
      if (stored == null) return null;
      final Uint8List bytes = base64Decode(stored);
      if (bytes.length != 32) return null;
      return E2eeCipher.forMasterKey(SecretKey(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Clears active cipher from memory.
  void lock() {
    // Ends a restore in flight too: a key the user just locked must not
    // land again a moment later.
    _generation++;
    _restoring = null;
    _setCipher(null);
  }

  /// Clears active cipher and removes MEK from local keyring.
  Future<void> forgetKey({required String userId}) async {
    lock();
    await _secureStore.delete(_keyStoreKey(userId));
  }
}

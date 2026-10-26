import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../auth/data/secure_auth_storage.dart';
import '../../logs/domain/log_event.dart';
import '../domain/e2ee_cipher.dart';
import '../domain/e2ee_settings_store.dart';
import '../domain/media_sync.dart';
import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';
import 'encrypted_media_store.dart';
import 'encrypted_sync_transport.dart';

export '../domain/e2ee_settings_store.dart' show E2eePublicParams;

class InvalidE2eePassphraseException implements Exception {
  const InvalidE2eePassphraseException([this.message = 'Invalid E2EE passphrase']);
  final String message;

  @override
  String toString() => 'InvalidE2eePassphraseException: $message';
}

/// [E2eeService.unlock] on an account the server has no row for: the
/// device believed it was locked and the server says there is nothing to
/// unlock, so the caller offers set-up instead.
class E2eeNotSetUpException implements Exception {
  const E2eeNotSetUpException();

  @override
  String toString() =>
      'E2eeNotSetUpException: encryption is not set up for this account';
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
/// Whether the account is encrypted is a server fact ([E2eeSettingsStore]):
/// with a row there and no key here the device is *locked* and every run is
/// refused, because a plaintext push from a new device would sit next to
/// sealed rows under the same owner. An account the server says has no row
/// is *plaintext unconfirmed* and also refused, until the user confirms once
/// ([confirmPlaintext]); only then does it sync in plaintext, and the Queue
/// keeps saying so. The confirmation exists because "no row" is an answer a
/// server can give falsely to hide an encrypted account (#379).
///
/// A [ChangeNotifier] so the Queue can say which of the four it is (unlocked,
/// locked, plaintext unconfirmed, confirmed plaintext): notifies whenever
/// [cipher], [hasIdentity], [keyOnServer] or the confirmation changes.
class E2eeService extends ChangeNotifier {
  E2eeService({
    SecureValueStore? secureStore,
    E2eeKeyDerivation? kdf,
    E2eeSettingsStore? settings,
    this.keyringTimeout = defaultKeyringTimeout,
  })  : _secureStore = secureStore ?? const FlutterSecureValueStore(),
        _kdf = kdf ?? E2eeKeyDerivation(),
        _settings = settings;

  final SecureValueStore _secureStore;
  final E2eeKeyDerivation _kdf;

  /// Null where there is no server to ask (tests, a build without Supabase):
  /// every account then reads as never set up.
  final E2eeSettingsStore? _settings;

  /// A keyring that never answers (a locked prompt) must not refuse every
  /// run for the rest of the session; past this a read counts as "no key".
  /// The server row lookup is boxed the same way, and past it counts as
  /// "unknown" — which refuses runs, see [keyOnServer].
  final Duration keyringTimeout;
  static const Duration defaultKeyringTimeout = Duration(seconds: 10);

  E2eeCipher? _cipher;
  String? _userId;
  bool? _keyOnServer;

  /// The user confirmed syncing this account without encryption (this
  /// session, or a keyring flag from an earlier one). Only meaningful while
  /// [_keyOnServer] is false; cleared the moment the account turns out
  /// encrypted.
  bool _plaintextConfirmed = false;
  int _generation = 0;
  Future<void>? _restoring;
  bool _disposed = false;

  bool get isUnlocked => _cipher != null;
  E2eeCipher? get cipher => _cipher;

  /// Whether the followed account has a `user_e2ee_settings` row: true once
  /// set up (here or on another device), false when the server confirmed
  /// there is none, null while unknown — not looked up yet, or the lookup
  /// failed. Unknown is treated like true wherever it matters: a run is
  /// refused rather than let out in plaintext over rows that may be sealed.
  bool? get keyOnServer => _keyOnServer;

  /// Signed in, settled, no key here, and the server has (or may have) one:
  /// runs are refused until [unlock]. The state a second device starts in.
  bool get isLocked =>
      hasIdentity && !isRestoring && !isUnlocked && _keyOnServer != false;

  /// Signed in, settled, no key anywhere, and the user confirmed syncing
  /// without encryption: runs leave in plaintext, and the Queue keeps saying
  /// so until [enroll].
  bool get isPlaintext =>
      hasIdentity &&
      !isRestoring &&
      !isUnlocked &&
      _keyOnServer == false &&
      _plaintextConfirmed;

  /// The fourth state: the server answered "no row" but nobody has confirmed
  /// plaintext yet, so runs are refused like in [isLocked]. A row hidden by
  /// the server must not flip a device to plaintext without a human seeing
  /// the banner (#379). Without a settings store there is no server that
  /// could lie, so the account counts as confirmed (see [followIdentity]).
  bool get isPlaintextUnconfirmed =>
      hasIdentity &&
      !isRestoring &&
      !isUnlocked &&
      _keyOnServer == false &&
      !_plaintextConfirmed;

  /// Whether [followIdentity] last saw a signed-in user. With an identity
  /// and no key, every sync run leaves in plaintext — the state the Queue
  /// has to show.
  bool get hasIdentity => _userId != null;

  /// Whether the followed user's key is still being read from the keyring,
  /// or the server still asked whether one exists. Runs are refused
  /// meanwhile (see [wrapTransport]), so the Queue has no plaintext to warn
  /// about yet.
  bool get isRestoring => _restoring != null;

  void _setCipher(E2eeCipher? cipher) {
    if (_disposed || identical(cipher, _cipher)) return;
    _cipher = cipher;
    notifyListeners();
  }

  void _setKeyOnServer(bool? value) {
    if (_disposed || value == _keyOnServer) return;
    _keyOnServer = value;
    // An encrypted account has nothing left to confirm.
    if (value == true && _userId != null) _clearPlaintextConfirmation(_userId!);
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
    _keyOnServer = null;
    _plaintextConfirmed = false;
    _restoring = null;
    if (!_disposed) notifyListeners();
    if (userId == null) return Future<void>.value();
    final Future<void> restore = _readKeyring(userId).then((E2eeCipher? restored) async {
      if (generation != _generation) return;
      // A key in the keyring was put there by set-up or unlock, both of
      // which saw the row; only a device without one has to ask.
      final bool? onServer = restored != null ? true : await _readServerKey(userId);
      if (generation != _generation) return;
      // Only a real server's "no row" needs a human; with no settings store
      // nothing can lie, so there is nothing to confirm.
      final bool confirmed = onServer == false &&
          (_settings == null || await _readPlaintextConfirmed(userId));
      if (generation != _generation) return;
      if (restored != null) _clearPlaintextConfirmation(userId);
      _keyOnServer = onServer;
      _plaintextConfirmed = confirmed;
      _restoring = null;
      if (!_disposed) notifyListeners(); // `isRestoring`, `keyOnServer` changed
      _setCipher(restored);
    });
    return _restoring = restore;
  }

  /// Whether the server holds parameters for [userId]; null when it could
  /// not be asked, which [wrapTransport] treats as "refuse the run".
  Future<bool?> _readServerKey(String userId) async {
    final E2eeSettingsStore? settings = _settings;
    if (settings == null) return false;
    try {
      final E2eePublicParams? params =
          await settings.read(userId).timeout(keyringTimeout);
      return params != null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the keyring holds the user's earlier confirmation. A keyring
  /// that errors or never answers reads as "not confirmed": it asks again
  /// rather than silently allowing plaintext.
  Future<bool> _readPlaintextConfirmed(String userId) async {
    try {
      final String? stored = await _secureStore
          .read(_plaintextOkKey(userId))
          .timeout(keyringTimeout, onTimeout: () => null);
      return stored == '1';
    } catch (_) {
      return false;
    }
  }

  /// The user's one-time answer to the [isPlaintextUnconfirmed] banner: sync
  /// this account without encryption. Refused when there is nothing to
  /// confirm — while the state is still being read, with a key held, or when
  /// the account is (or may be) encrypted. Flips in memory first so the
  /// Queue follows at once; the keyring write is best effort, because a
  /// failed one only means the next launch asks again.
  Future<void> confirmPlaintext() async {
    final String userId = _requireIdentity();
    if (isRestoring || isUnlocked || _keyOnServer != false) {
      throw StateError('nothing to confirm: this account is not known to be unencrypted');
    }
    if (_plaintextConfirmed) return;
    _plaintextConfirmed = true;
    if (!_disposed) notifyListeners();
    try {
      await _secureStore.write(_plaintextOkKey(userId), '1');
    } catch (_) {}
  }

  /// The account turned out encrypted: forget the plaintext confirmation, in
  /// memory and in the keyring, so it cannot outlive the state it answered.
  /// Best effort and unawaited, like every sink here.
  void _clearPlaintextConfirmation(String userId) {
    _plaintextConfirmed = false;
    unawaited(
      Future<void>.sync(() => _secureStore.delete(_plaintextOkKey(userId)))
          .catchError((Object _) {}),
    );
  }

  /// The signed-in user the passphrase flow acts for: [enroll] and [unlock]
  /// take no id because the key must bind to the followed identity and no
  /// other, and a dialog would otherwise carry a stale one across a sign-out.
  String _requireIdentity() {
    final String? userId = _userId;
    if (userId == null) throw StateError('sign in before setting up encryption');
    return userId;
  }

  /// After every `await` in a flow that ends in a held key: the identity
  /// captured at entry must still be the followed one and nothing
  /// ([followIdentity], [lock], another flow) may have moved the service on
  /// since — otherwise a key derived for A lands while B is signed in, or
  /// lands at all after a sign-out.
  void _checkStill(String userId, int generation) {
    if (_userId != userId || _generation != generation) {
      throw StateError('signed-in user changed');
    }
  }

  E2eeSettingsStore _requireSettings() {
    final E2eeSettingsStore? settings = _settings;
    if (settings == null) {
      throw StateError('encryption settings are not available in this build');
    }
    return settings;
  }

  /// First-time set-up for the followed account: derives a key from
  /// [passphrase], publishes its public parameters, then activates it here.
  /// The row is written **before** the key is held, so a failed write leaves
  /// no key that could seal rows the server has no parameters for; and it
  /// is an insert, never an upsert, so a device that lost a race gets
  /// [E2eeSettingsConflictException] and unlocks instead of publishing a
  /// second key over the first device's envelopes.
  Future<void> enroll(String passphrase) async {
    final String userId = _requireIdentity();
    final E2eeSettingsStore settings = _requireSettings();
    int generation = _generation;
    final (SecretKey key, E2eePublicParams params) = await _deriveFresh(passphrase);
    _checkStill(userId, generation);
    try {
      await settings.create(userId, params);
    } on E2eeSettingsConflictException {
      // The row exists, whoever wrote it: this device is locked from here.
      if (_userId == userId) _setKeyOnServer(true);
      rethrow;
    } catch (_) {
      // A timeout or a dropped connection may have committed server-side;
      // nobody knows, so nothing may leave plain until it is re-read.
      if (_userId == userId) _setKeyOnServer(null);
      rethrow;
    }
    // The row is there now, whatever happens to the keyring below: a
    // device that cannot hold the key is locked, not plaintext. A restore
    // still in flight for this user carries a stale "no row" and must not
    // land it over this, so it is ended here, not only in `_activate`.
    if (_userId == userId) {
      generation = ++_generation;
      _restoring = null;
      _setKeyOnServer(true);
    }
    _checkStill(userId, generation);
    await _activate(userId, key, generation: generation);
  }

  /// Unlock on a device without the key: reads the account's parameters,
  /// checks [passphrase] against them and, when it matches, holds the key.
  /// Throws [InvalidE2eePassphraseException] for a wrong passphrase and
  /// [E2eeNotSetUpException] when the account was never set up — which
  /// also corrects [keyOnServer], so a device that only *thought* it was
  /// locked (the lookup had failed) can go on to set-up.
  Future<void> unlock(String passphrase) async {
    final String userId = _requireIdentity();
    final E2eeSettingsStore settings = _requireSettings();
    final int generation = _generation;
    final E2eePublicParams? params;
    try {
      params = await settings.read(userId).timeout(keyringTimeout);
    } catch (_) {
      if (_userId == userId) _setKeyOnServer(null);
      rethrow;
    }
    _checkStill(userId, generation);
    if (params == null) {
      _setKeyOnServer(false);
      throw const E2eeNotSetUpException();
    }
    _setKeyOnServer(true);
    final SecretKey key = await _verify(passphrase, params);
    _checkStill(userId, generation);
    await _activate(userId, key, generation: generation);
  }

  /// A plaintext run's one check: `keyOnServer == false` was read once, at
  /// sign-in, and another device may have set the account up since. The
  /// plain transport and store handed out by [wrapTransport] and
  /// [wrapMediaStore] ask again before their first call and refuse the run
  /// if a row appeared — the state flips to locked, and the Queue follows.
  /// Only that answer moves the state: a lookup that fails refuses this
  /// run and nothing more, so an offline blip does not pin an account that
  /// never set up encryption to locked; and a stale "no row" that lands
  /// after a set-up went through is a no-op, not a write back to plaintext.
  Future<void> _assertStillPlaintext(String userId) async {
    final bool? onServer = await _readServerKey(userId);
    switch (onServer) {
      case false:
        return;
      case true:
        if (_userId == userId) _setKeyOnServer(true);
        throw StateError(
          'sync skipped: encryption was set up on another device; unlock with your passphrase',
        );
      case null:
        throw StateError(
          'sync skipped: could not check whether this account is encrypted',
        );
    }
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

  /// With no key here, a run may leave in plaintext only once the server
  /// confirmed the account was never set up *and* the user confirmed syncing
  /// without encryption. A row there means this device
  /// is locked; an unanswered lookup means nobody knows, and the run waits.
  void _checkPlaintextAllowed() {
    switch (_keyOnServer) {
      case false:
        if (!_plaintextConfirmed) {
          throw StateError(
            'sync skipped: this device has no encryption key; confirm SYNC WITHOUT ENCRYPTION in the Queue or set up a passphrase',
          );
        }
        return;
      case true:
        throw StateError(
          'sync skipped: encryption is locked on this device; unlock with your passphrase',
        );
      case null:
        throw StateError(
          'sync skipped: could not check whether this account is encrypted',
        );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  /// The transport the engine runs over: [inner] sealed under the current
  /// key, or [inner] itself while no key is held and the user confirmed
  /// plaintext (an unconfirmed or locked device is refused). Called by the
  /// resolver on every run, so a key that arrives later applies to the next
  /// run and never redirects one in flight. Confirmed plaintext rows leave
  /// plain — the Queue's sync status says so (`NOT ENCRYPTED`); nothing here
  /// hides it.
  SyncTransport wrapTransport(
    SyncTransport inner, {
    required String ownerId,
    LogSink log = const NoopLogSink(),
  }) {
    _checkOwner(ownerId);
    final E2eeCipher? cipher = _cipher;
    if (cipher == null) {
      _checkPlaintextAllowed();
      // The launch sync and the edit-debounce sync show no panel, so this
      // line is the one trace of a plaintext run those paths leave.
      log.log(
        'Sync: no encryption key on this device; rows leave in plaintext',
        level: LogLevel.warn,
      );
      return _PlaintextGuardTransport(inner, () => _assertStillPlaintext(ownerId));
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
    if (cipher == null) {
      _checkPlaintextAllowed();
      return _PlaintextGuardMediaStore(inner, () => _assertStillPlaintext(ownerId));
    }
    return EncryptedMediaStore(inner: inner, cipher: cipher, ownerId: ownerId);
  }

  static String _keyStoreKey(String userId) =>
      'ai.augustyniak.capture.e2ee.mek.$userId';

  /// Holds `'1'` once the user confirmed syncing [userId]'s account without
  /// encryption. Per user and in the keyring, so a reinstall asks again.
  static String _plaintextOkKey(String userId) =>
      'ai.augustyniak.capture.e2ee.plaintext-ok.$userId';

  /// Sets up a new passphrase, generates a fresh salt, derives the 256-bit MEK,
  /// persists the MEK in the local OS keyring, and returns the public KDF parameters.
  ///
  /// The primitive under [enroll], without the server row: it holds a key
  /// the server has no parameters for, which is what [enroll] exists to
  /// prevent, so nothing in the app calls it.
  @visibleForTesting
  Future<E2eePublicParams> setupPassphrase({
    required String userId,
    required String passphrase,
  }) async {
    _claim(userId);
    final int generation = _generation;
    final (SecretKey key, E2eePublicParams params) = await _deriveFresh(passphrase);
    await _activate(userId, key, generation: generation);
    return params;
  }

  /// A fresh salt and the key [passphrase] derives under it, with the public
  /// parameters a second device needs to derive the same key. Pure: nothing
  /// is held or written until [_activate].
  Future<(SecretKey, E2eePublicParams)> _deriveFresh(String passphrase) async {
    final List<int> salt = _kdf.generateSalt();
    final SecretKey key = await _kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
    );
    final String keyCheckHash = await _kdf.computeKeyCheckHash(
      key: key,
      salt: salt,
    );
    return (
      key,
      E2eePublicParams(
        saltBase64: base64Encode(salt),
        keyCheckHash: keyCheckHash,
        iterations: _kdf.iterations,
      ),
    );
  }

  /// Persists [key] in the keyring under [userId] and starts sealing with
  /// it. Every path here saw the account's row (or, for [setupPassphrase],
  /// is the caller about to write it), so the account counts as set up.
  /// Checked against [generation] after the keyring write, before the key
  /// is held — the one `await` here that can straddle an identity change —
  /// and ends any restore in flight so it cannot land on top of the newer
  /// key.
  Future<void> _activate(
    String userId,
    SecretKey key, {
    required int generation,
  }) async {
    final E2eeCipher cipher = await E2eeCipher.forMasterKey(key);
    final List<int> keyBytes = await key.extractBytes();
    await _secureStore.write(
      _keyStoreKey(userId),
      base64Encode(keyBytes),
    );
    _checkStill(userId, generation);
    _generation++;
    _restoring = null;
    _keyOnServer = true;
    _clearPlaintextConfirmation(userId);
    _setCipher(cipher);
  }

  /// The key [passphrase] derives under [params], or
  /// [InvalidE2eePassphraseException] when its check tag does not match.
  /// Derives with the row's own iteration count, never this build's
  /// default, which may since have been raised.
  Future<SecretKey> _verify(String passphrase, E2eePublicParams params) async {
    if (params.algorithm != 'pbkdf2_sha256') {
      throw InvalidE2eePassphraseException(
        'This key uses a derivation this build does not support '
        '(${params.algorithm})',
      );
    }
    if (!params.keyCheckHash.startsWith(E2eeKeyDerivation.keyCheckPrefix)) {
      // A pre-#298 row stored `sha256(key || salt)`; nothing derives that
      // any more, and reporting it as a wrong passphrase would send the user
      // retyping a passphrase that is right.
      throw const InvalidE2eePassphraseException(
        'This key was set up by an older build and cannot be verified by '
        'this one',
      );
    }
    final Uint8List salt = base64Decode(params.saltBase64);
    final E2eeKeyDerivation kdf = params.iterations == _kdf.iterations
        ? _kdf
        : E2eeKeyDerivation(iterations: params.iterations);
    final SecretKey key = await kdf.deriveKey(passphrase: passphrase, salt: salt);
    final String actualHash = await kdf.computeKeyCheckHash(key: key, salt: salt);
    if (actualHash != params.keyCheckHash) {
      throw const InvalidE2eePassphraseException();
    }
    return key;
  }

  /// Verifies a passphrase against the remote salt and keyCheckHash, derives the MEK,
  /// saves it to the local OS keyring, and activates encryption.
  /// Throws [InvalidE2eePassphraseException] if passphrase is incorrect.
  ///
  /// The primitive under [unlock], with the row's parameters passed in
  /// rather than read; nothing in the app calls it.
  @visibleForTesting
  Future<bool> unlockWithPassphrase({
    required String userId,
    required String passphrase,
    required String saltBase64,
    required String expectedCheckHash,
    required int iterations,
  }) async {
    _claim(userId);
    final int generation = _generation;
    final SecretKey key = await _verify(
      passphrase,
      E2eePublicParams(
        saltBase64: saltBase64,
        keyCheckHash: expectedCheckHash,
        iterations: iterations,
      ),
    );
    await _activate(userId, key, generation: generation);
    return true;
  }

  /// Attempts to restore an already unlocked MEK from the local keyring on app launch.
  ///
  /// The primitive under [followIdentity]'s restore; nothing in the app
  /// calls it directly.
  @visibleForTesting
  Future<bool> tryRestoreFromKeyring({required String userId}) async {
    _claim(userId);
    final int generation = _generation;
    final E2eeCipher? restored = await _readKeyring(userId);
    if (restored == null || generation != _generation) return false;
    _setKeyOnServer(true);
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
      return await E2eeCipher.forMasterKey(SecretKey(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Clears active cipher from memory. [keyOnServer] is untouched: the
  /// account stays encrypted, this device is merely locked, and runs are
  /// refused until [unlock] or the keyring restore on the next launch.
  void lock() {
    // Ends a restore in flight too: a key the user just locked must not
    // land again a moment later.
    _generation++;
    _restoring = null;
    _setCipher(null);
  }

  /// Clears active cipher and removes MEK from local keyring. The server
  /// row stays — there is no client-side delete, by design — so the next
  /// launch finds the account encrypted and this device locked.
  Future<void> forgetKey({required String userId}) async {
    lock();
    await _secureStore.delete(_keyStoreKey(userId));
  }
}

/// The plain transport of a plaintext run, with `E2eeService`'s re-check in
/// front of its first call: one server read per run, shared by push and
/// pull, so a row another device wrote since sign-in refuses the run
/// instead of letting plaintext land next to sealed rows.
class _PlaintextGuardTransport implements SyncTransport {
  _PlaintextGuardTransport(this._inner, this._check);

  final SyncTransport _inner;
  final Future<void> Function() _check;
  late final Future<void> _checked = _check();

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async {
    await _checked;
    return _inner.push(table, rows);
  }

  @override
  Future<SyncPage> pull(
    SyncTable table, {
    required DateTime? since,
    required Map<String, Object?>? after,
    required int limit,
  }) async {
    await _checked;
    return _inner.pull(table, since: since, after: after, limit: limit);
  }

  @override
  Future<DateTime> serverNow() async {
    await _checked;
    return _inner.serverNow();
  }
}

/// [_PlaintextGuardTransport]'s counterpart for the media store.
class _PlaintextGuardMediaStore implements MediaObjectStore {
  _PlaintextGuardMediaStore(this._inner, this._check);

  final MediaObjectStore _inner;
  final Future<void> Function() _check;
  late final Future<void> _checked = _check();

  @override
  Future<bool> exists(String key) async {
    await _checked;
    return _inner.exists(key);
  }

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {
    await _checked;
    return _inner.upload(key, source, sha256: sha256);
  }

  @override
  Stream<List<int>> download(String key, {required int maxBytes}) async* {
    await _checked;
    await for (final List<int> chunk in _inner.download(
      key,
      maxBytes: maxBytes,
    )) {
      yield chunk;
    }
  }
}

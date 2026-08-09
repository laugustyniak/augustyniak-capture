import 'aes_gcm_token_cipher.dart';

/// Reads the master key from [primary], taking it over from [fallback] once if
/// that is where it still lives, and retiring the old copy only after the new
/// one has proven it kept the value.
///
/// **This is what makes the key store swappable without a migration script.**
/// The key has moved twice now — keyring, then a file beside the database when
/// ad-hoc rebuilds made the keychain ACL unusable, then back to the keyring
/// once builds carried a stable signature (see `LOCAL_SIGN_IDENTITY` in
/// CLAUDE.md). Each move has to be non-destructive, because on the other side
/// of it sit every already-sealed provider token.
///
/// Three rules hold it together, and none is optional:
///
/// - **A refusing [primary] throws rather than falling through to [fallback].**
///   It is the one decision that separates this from a cache. The point of
///   moving the key back into the keyring is that it stops sitting next to the
///   ciphertext it opens; silently answering from the old file whenever the
///   keyring says no would keep that file load-bearing forever and hide the
///   failure while doing it. The throw reaches [AesGcmTokenCipher], which turns
///   it into `unavailableReason` — the Models tab then says the tokens are
///   encrypted and unreadable instead of pretending everything is fine.
/// - **[retireFallback] runs only after a write *and a read-back*.** A store
///   that accepts a write and drops it is a real shape — it is why
///   `AesGcmTokenCipher` verifies its own generated key the same way. Deleting
///   the old copy on the strength of a successful write would destroy the only
///   key in existence at exactly the moment the new home turned out not to be
///   one.
/// - **A failed migration is not an error.** The key is handed back regardless,
///   so the session decrypts normally and the next launch simply retries. The
///   fallback stays where it is until the handover demonstrably worked.
///
/// An unreadable [fallback] is likewise not an error: on an install that never
/// had one, "no old key here" and "no old store here" are the same answer.
class MigratingMasterKeyStore implements MasterKeyStore {
  MigratingMasterKeyStore({
    required MasterKeyStore primary,
    required MasterKeyStore fallback,
    Future<void> Function()? retireFallback,
  }) : _primary = primary,
       _fallback = fallback,
       _retireFallback = retireFallback;

  final MasterKeyStore _primary;
  final MasterKeyStore _fallback;
  final Future<void> Function()? _retireFallback;

  @override
  Future<String?> read() async {
    // Deliberately unguarded: a throw here is the keyring refusing, and that
    // has to reach the user rather than be answered from the old file.
    final String? own = await _primary.read();
    if (own != null && own.trim().isNotEmpty) {
      await _retireRedundantFallback(own);
      return own;
    }

    String? inherited;
    try {
      inherited = await _fallback.read();
    } catch (_) {
      return null;
    }
    if (inherited == null || inherited.trim().isEmpty) return null;

    await _handOver(inherited);
    return inherited;
  }

  @override
  Future<void> write(String value) => _primary.write(value);

  /// Delete the fallback when it holds exactly the key the primary just
  /// returned, and only then.
  ///
  /// Retiring solely at the end of a migration would miss the state an install
  /// is left in by the *previous* arrangement, which copied the key instead of
  /// moving it: both stores hold it, the migration path never runs because the
  /// primary answers first, and the old copy survives every launch. The move
  /// would look done while the key still sat beside the ciphertext.
  ///
  /// Equality is the whole safety argument. A fallback holding a *different*
  /// key is not a leftover — the values on disk may be sealed under it — and
  /// deleting that is the one irreversible mistake this class can make.
  Future<void> _retireRedundantFallback(String key) async {
    if (_retireFallback == null) return;
    try {
      final String? leftover = await _fallback.read();
      if (leftover == null || leftover.trim() != key.trim()) return;
      await _retireFallback();
    } catch (_) {
      // Nothing to clean up, or it could not be read. Either way the live key
      // is in the primary store and the launch carries on.
    }
  }

  /// Move [key] into the primary store, and retire the old copy only once the
  /// primary hands the same value back.
  Future<void> _handOver(String key) async {
    try {
      await _primary.write(key);
      if (await _primary.read() != key) return;
    } catch (_) {
      // Could not write, or could not read back. The caller still gets the
      // key; the next launch tries the handover again.
      return;
    }
    try {
      await _retireFallback?.call();
    } catch (_) {
      // The key is safely in the primary store by now, so a leftover copy is
      // untidy rather than dangerous — and never worth failing a launch over.
    }
  }
}

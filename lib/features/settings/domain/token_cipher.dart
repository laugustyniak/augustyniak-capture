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

  /// Why [encrypts] is false, in one short human-readable line, or null when there
  /// is nothing to explain (encryption is on, or this implementation never
  /// encrypts by design).
  ///
  /// It exists because "no keyring" is the *only* way this layer can fail and
  /// the failure is otherwise indistinguishable from a deliberate plaintext
  /// fallback: the macOS entitlement bug that kept encryption off for the whole
  /// life of the feature looked exactly like a headless Linux box with no
  /// Secret Service. One line of cause on screen is what separates them.
  String? get unavailableReason => null;

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

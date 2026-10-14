/// What the server keeps about a user's key: enough for a second device to
/// re-derive it from the passphrase, and nothing that opens an envelope.
/// [iterations] travels with the salt so the KDF cost can be raised for new
/// keys without orphaning the ones already derived — see
/// `E2eeKeyDerivation`.
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

/// Thrown by [E2eeSettingsStore.create] when the account already has a row:
/// another device set the passphrase up first, and this one has to unlock
/// with it rather than publish a second key.
class E2eeSettingsConflictException implements Exception {
  const E2eeSettingsConflictException();

  @override
  String toString() =>
      'E2eeSettingsConflictException: encryption is already set up for this account';
}

/// The `user_e2ee_settings` row for the signed-in user: the public KDF
/// parameters a passphrase is checked against. One row per account, written
/// once at set-up and never updated by the client — a second key would
/// orphan every envelope sealed under the first.
abstract interface class E2eeSettingsStore {
  /// The account's parameters, or null when encryption was never set up.
  /// Throws when the row cannot be read or is malformed: "unknown" must not
  /// read as "none", because "none" is what lets a run leave in plaintext.
  Future<E2eePublicParams?> read(String ownerId);

  /// Inserts the row. Throws [E2eeSettingsConflictException] when one
  /// exists; never overwrites.
  Future<void> create(String ownerId, E2eePublicParams params);
}

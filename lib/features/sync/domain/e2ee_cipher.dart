import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class E2eeDecryptionException implements Exception {
  const E2eeDecryptionException([this.message = 'Decryption failed']);
  final String message;

  @override
  String toString() => 'E2eeDecryptionException: $message';
}

/// Derives the master encryption key (MEK) from a passphrase with
/// PBKDF2-HMAC-SHA256, and the key-check tag that lets a second device
/// confirm a passphrase before it trusts the key it derived.
///
/// **The iteration count is a parameter, stored next to the salt on the
/// server, never a constant.** The server-side verifier is an offline guess
/// oracle by construction — anyone with database read can run the KDF
/// against it — so the KDF's cost is the only thing between a leaked
/// `user_e2ee_settings` row and the passphrase. A count baked into the
/// client could never be raised without orphaning every existing key; one
/// that travels with the salt can. [defaultIterations] follows OWASP's
/// PBKDF2-HMAC-SHA256 figure; it costs about 1.5 s in pure Dart on a
/// desktop and is paid once per passphrase entry, never per sync.
///
/// The check tag is domain-separated from the data key: both are HKDF
/// outputs of the MEK under different `info` strings, so the value that sits
/// on the server is not the key that opens a single envelope, and the AES
/// key is never used under a second algorithm.
class E2eeKeyDerivation {
  /// Throws [ArgumentError] for a count outside [minIterations] ..
  /// [maxIterations]. The count arrives from the server row on a second
  /// device, so the bound is what stops a hostile value from either
  /// weakening the derivation or pinning the unlock for hours.
  E2eeKeyDerivation({this.iterations = defaultIterations})
      : _pbkdf2 = Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: _checked(iterations),
          bits: 256,
        );

  static const int defaultIterations = 600000;
  static const int minIterations = 1000;
  static const int maxIterations = 10000000;

  static int _checked(int iterations) {
    if (iterations < minIterations || iterations > maxIterations) {
      throw ArgumentError.value(
        iterations,
        'iterations',
        'must be between $minIterations and $maxIterations',
      );
    }
    return iterations;
  }

  /// Prefix of a check tag produced by this version of the derivation, so a
  /// future change to the tag's construction can tell an old row apart
  /// rather than reporting every stored passphrase as wrong.
  static const String keyCheckPrefix = 'kc1:';

  final int iterations;
  final Pbkdf2 _pbkdf2;

  List<int> generateSalt([int length = 16]) {
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKey> deriveKey({
    required String passphrase,
    required List<int> salt,
  }) {
    return _pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
  }

  /// The tag stored on the server as `key_check_hash`: an HKDF output of the
  /// master key under the key-check domain, hex-encoded behind
  /// [keyCheckPrefix]. Equal only for the same master key and salt.
  Future<String> computeKeyCheckHash({
    required SecretKey key,
    required List<int> salt,
  }) async {
    final SecretKey tag = await E2eeCipher._hkdf.deriveKey(
      secretKey: key,
      nonce: salt,
      info: utf8.encode(E2eeCipher._keyCheckInfo),
    );
    final List<int> bytes = await tag.extractBytes();
    return '$keyCheckPrefix${_hex(bytes)}';
  }

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Authenticated encryption for everything that leaves the device under
/// E2EE: AES-256-GCM, one random nonce per envelope, and **associated data
/// on every call**.
///
/// Envelope: `enc:v2:` + base64(12-byte nonce || ciphertext || 16-byte MAC).
/// The associated data is not stored in the envelope; it is the *context*
/// the envelope is only valid in — owner, table and row key for a sync row,
/// the object key for a media blob — and the caller supplies the same
/// context on the way back. GCM's tag covers it, so a ciphertext the server
/// transplants between two rows, two tables or two owners fails
/// authentication instead of decrypting into the wrong place. That is the
/// whole reason `aad` is a required parameter rather than a default: an
/// envelope sealed with no context is exactly the one a server can move.
///
/// `enc:v1:` envelopes carried no associated data. None were ever written
/// by a release (the layer was not wired when the format changed), so v1 is
/// refused outright rather than decrypted leniently.
class E2eeCipher {
  /// A cipher over [key] as given. Prefer [forMasterKey], which separates
  /// the data key from the master key; this constructor exists for the
  /// tests and for a key that is already a derived data key.
  E2eeCipher({required SecretKey key}) : _key = key;

  /// The data key for [masterKey]: HKDF under the data domain, so the key
  /// that opens an envelope is never the one the key-check tag is derived
  /// from, and the master key itself is never handed to AES.
  static Future<E2eeCipher> forMasterKey(SecretKey masterKey) async {
    final SecretKey dataKey = await _hkdf.deriveKey(
      secretKey: masterKey,
      info: utf8.encode(_dataKeyInfo),
    );
    return E2eeCipher(key: dataKey);
  }

  static const String sealedPrefix = 'enc:v2:';
  static const String _legacyPrefix = 'enc:v1:';
  static const String _envelopeMarker = 'enc:';
  static const int _macLengthBytes = 16;
  static const String _dataKeyInfo = 'ai.augustyniak.capture/e2ee/data/v1';
  static const String _keyCheckInfo =
      'ai.augustyniak.capture/e2ee/key-check/v1';

  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final SecretKey _key;
  final AesGcm _algorithm = AesGcm.with256bits();

  /// True for any E2EE envelope — this version, an older one or a newer one
  /// — "this value is ciphertext, not content", which is what a reader
  /// deciding whether a row is usable needs to know. Whether it can be
  /// *opened* is [unseal]'s answer. A build that meets a version it does not
  /// know therefore skips the row and holds its cursor, the same as for a
  /// key it does not have.
  static bool isSealed(String? value) =>
      value != null && value.startsWith(_envelopeMarker);

  /// Seals UTF-8 text into an authenticated envelope bound to [aad].
  Future<String> seal(String plaintext, {required List<int> aad}) async {
    final List<int> clearBytes = utf8.encode(plaintext);
    final List<int> boxBytes = await sealBytes(clearBytes, aad: aad);
    return '$sealedPrefix${base64Encode(boxBytes)}';
  }

  /// Unseals an envelope back into UTF-8 text under the same [aad] it was
  /// sealed with. Throws [E2eeDecryptionException] on a wrong key, a
  /// different context, corrupt data or an altered MAC.
  Future<String> unseal(String sealed, {required List<int> aad}) async {
    if (sealed.startsWith(_legacyPrefix)) {
      throw const E2eeDecryptionException(
        'enc:v1 envelope carries no associated data and is not accepted',
      );
    }
    if (!sealed.startsWith(sealedPrefix)) {
      throw const E2eeDecryptionException('Not an E2EE sealed envelope');
    }
    final String b64 = sealed.substring(sealedPrefix.length);
    Uint8List boxBytes;
    try {
      boxBytes = base64Decode(b64);
    } catch (e) {
      throw E2eeDecryptionException('Corrupt base64 envelope: $e');
    }
    final List<int> clearBytes = await unsealBytes(boxBytes, aad: aad);
    try {
      return utf8.decode(clearBytes);
    } catch (e) {
      throw E2eeDecryptionException('Corrupt UTF-8 cleartext: $e');
    }
  }

  /// Seals binary bytes (12-byte nonce || ciphertext || 16-byte MAC) bound
  /// to [aad].
  Future<List<int>> sealBytes(
    List<int> clearBytes, {
    required List<int> aad,
  }) async {
    final SecretBox box = await _algorithm.encrypt(
      clearBytes,
      secretKey: _key,
      aad: aad,
    );
    return box.concatenation();
  }

  /// Unseals binary bytes under [aad]. Throws [E2eeDecryptionException] on
  /// failure.
  Future<List<int>> unsealBytes(
    List<int> boxBytes, {
    required List<int> aad,
  }) async {
    try {
      final SecretBox box = SecretBox.fromConcatenation(
        boxBytes,
        nonceLength: AesGcm.defaultNonceLength,
        macLength: _macLengthBytes,
      );
      return await _algorithm.decrypt(box, secretKey: _key, aad: aad);
    } catch (e) {
      throw E2eeDecryptionException('Authentication failed or invalid key: $e');
    }
  }
}

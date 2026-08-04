import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/token_cipher.dart';

/// Where the 256-bit master key lives. One method pair so the OS keyring
/// (production) and an in-memory map (tests) are interchangeable — the same
/// seam shape as `LogArchive` and `MediaPicker`.
abstract class MasterKeyStore {
  Future<String?> read();

  Future<void> write(String value);
}

/// AES-256-GCM under a master key from [MasterKeyStore].
///
/// On-disk format: `enc:v1:` + base64 of the `cryptography` package's
/// SecretBox concatenation — 12-byte nonce, ciphertext, 16-byte MAC.
///
/// [ensureReady] loads or creates the key and never throws: any key-store
/// failure (no keyring daemon, locked Secret Service, missing plugin in a
/// test binding) leaves [encrypts] false and every transform an identity —
/// the same clean degradation as a missing `tesseract` binary.
class AesGcmTokenCipher extends TokenCipher {
  AesGcmTokenCipher({required MasterKeyStore keyStore}) : _keyStore = keyStore;

  static const int _keyLengthBytes = 32;
  static const int _macLengthBytes = 16;

  final MasterKeyStore _keyStore;
  final AesGcm _algorithm = AesGcm.with256bits();

  SecretKey? _key;
  bool _ready = false;
  Future<void>? _initializing;

  @override
  bool get encrypts => _ready;

  @override
  Future<void> ensureReady() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final String? stored = await _keyStore.read();
      if (stored != null) {
        final Uint8List bytes = base64Decode(stored);
        if (bytes.length == _keyLengthBytes) {
          _key = SecretKey(bytes);
          _ready = true;
          return;
        }
        // Wrong-sized value: something else owns this entry — do not
        // overwrite it, run without encryption.
        return;
      }

      final SecretKey generated = await _algorithm.newSecretKey();
      final List<int> keyBytes = await generated.extractBytes();
      await _keyStore.write(base64Encode(keyBytes));
      // Read back: proves the keyring persisted the key rather than merely
      // accepting the call. Tokens sealed under an unpersisted key would be
      // unreadable after the next launch.
      final String? verified = await _keyStore.read();
      if (verified == null) {
        return;
      }
      _key = SecretKey(base64Decode(verified));
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  @override
  Future<String> seal(String token) async {
    final SecretKey? key = _key;
    if (!_ready || key == null || TokenCipher.isSealed(token)) {
      return token;
    }
    final SecretBox box =
        await _algorithm.encrypt(utf8.encode(token), secretKey: key);
    return '${TokenCipher.sealedPrefix}${base64Encode(box.concatenation())}';
  }

  @override
  Future<String> unseal(String stored) async {
    final SecretKey? key = _key;
    if (!_ready || key == null || !TokenCipher.isSealed(stored)) {
      return stored;
    }
    try {
      final Uint8List bytes =
          base64Decode(stored.substring(TokenCipher.sealedPrefix.length));
      final SecretBox box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: AesGcm.defaultNonceLength,
        macLength: _macLengthBytes,
      );
      final List<int> clear = await _algorithm.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      // Wrong key or corrupt data. Hand the blob back untouched so it is
      // written back verbatim — the token recovers if the keyring returns.
      return stored;
    }
  }
}

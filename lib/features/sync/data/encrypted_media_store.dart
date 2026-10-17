import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../domain/e2ee_cipher.dart';
import '../domain/media_sync.dart';

/// Decorator around [MediaObjectStore] that transparently encrypts media files
/// (audio/video/photos) before upload, and decrypts them after download using
/// Zero-Knowledge authenticated AES-256-GCM.
///
/// Cloud storage receives and stores only ciphertext; download yields the
/// original plaintext bytes that match the recording's local `contentHash`.
///
/// The envelope is bound to the owner and the object key as its associated
/// data, so a blob the server moves under another recording's key — or
/// another owner's folder, which the inner store prefixes outside the
/// cipher — fails to open rather than landing as that recording's audio.
class EncryptedMediaStore implements MediaObjectStore {
  EncryptedMediaStore({
    required MediaObjectStore inner,
    required E2eeCipher cipher,
    required String ownerId,
  })  : _inner = inner,
        _cipher = cipher,
        _ownerId = ownerId;

  final MediaObjectStore _inner;
  final E2eeCipher _cipher;
  final String _ownerId;

  List<int> _aad(String key) => utf8.encode('$_ownerId\n$key');

  @override
  Future<bool> exists(String key) => _inner.exists(key);

  @override
  Future<void> upload(
    String key,
    File source, {
    required String sha256,
  }) async {
    final List<int> clearBytes = await source.readAsBytes();
    final List<int> cipherBytes = await _cipher.sealBytes(
      clearBytes,
      aad: _aad(key),
    );

    final Directory tempDir =
        await Directory.systemTemp.createTemp('e2ee_media_upload_');
    final File tempFile = File('${tempDir.path}/upload.bin');
    try {
      await tempFile.writeAsBytes(cipherBytes);
      final String cipherSha256 =
          crypto.sha256.convert(cipherBytes).toString();
      await _inner.upload(key, tempFile, sha256: cipherSha256);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  @override
  Stream<List<int>> download(String key, {required int maxBytes}) async* {
    // The envelope is exactly the clear length plus a fixed overhead, so a
    // ceiling on the clear bytes is one on the ciphertext. The inner store
    // enforces it while the bytes arrive.
    final List<int> cipherBytes = <int>[];
    await for (final List<int> chunk in _inner.download(
      key,
      maxBytes: maxBytes + E2eeCipher.envelopeOverheadBytes,
    )) {
      cipherBytes.addAll(chunk);
    }
    yield await _cipher.unsealBytes(cipherBytes, aad: _aad(key));
  }
}

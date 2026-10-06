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
class EncryptedMediaStore implements MediaObjectStore {
  EncryptedMediaStore({
    required MediaObjectStore inner,
    required E2eeCipher cipher,
  })  : _inner = inner,
        _cipher = cipher;

  final MediaObjectStore _inner;
  final E2eeCipher _cipher;

  @override
  Future<bool> exists(String key) => _inner.exists(key);

  @override
  Future<void> upload(
    String key,
    File source, {
    required String sha256,
  }) async {
    final List<int> clearBytes = await source.readAsBytes();
    final List<int> cipherBytes = await _cipher.sealBytes(clearBytes);

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
  Future<List<int>> download(String key) async {
    final List<int> cipherBytes = await _inner.download(key);
    return await _cipher.unsealBytes(cipherBytes);
  }
}

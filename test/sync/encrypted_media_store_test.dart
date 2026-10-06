import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_media_store.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';

class FakeMediaStore implements MediaObjectStore {
  final Map<String, List<int>> storage = <String, List<int>>{};
  final Map<String, String> uploadedSha256 = <String, String>{};

  @override
  Future<bool> exists(String key) async => storage.containsKey(key);

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {
    storage[key] = await source.readAsBytes();
    uploadedSha256[key] = sha256;
  }

  @override
  Future<List<int>> download(String key) async {
    if (!storage.containsKey(key)) {
      throw StateError('Not found: $key');
    }
    return storage[key]!;
  }
}

void main() {
  late E2eeCipher cipher;
  late FakeMediaStore innerStore;
  late EncryptedMediaStore encryptedStore;
  late Directory tempDir;

  setUp(() async {
    final kdf = E2eeKeyDerivation();
    final salt = kdf.generateSalt();
    final key = await kdf.deriveKey(passphrase: 'audio-encryption-key', salt: salt);
    cipher = E2eeCipher(key: key);
    innerStore = FakeMediaStore();
    encryptedStore = EncryptedMediaStore(inner: innerStore, cipher: cipher);
    tempDir = await Directory.systemTemp.createTemp('e2ee_media_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('upload encrypts audio file bytes before sending to underlying store', () async {
    final audioFile = File('${tempDir.path}/sample.m4a');
    final plainAudioBytes = utf8.encode('RIFF....Simulated audio capture bytes');
    await audioFile.writeAsBytes(plainAudioBytes);
    final plainSha256 = crypto.sha256.convert(plainAudioBytes).toString();

    const storageKey = 'user123/captures/rec1/sample.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: plainSha256);

    // Stored bytes in backend are encrypted, NOT plaintext
    expect(innerStore.storage.containsKey(storageKey), isTrue);
    final storedRawBytes = innerStore.storage[storageKey]!;
    expect(storedRawBytes, isNot(equals(plainAudioBytes)));

    // Uploaded SHA-256 metadata matches ciphertext bytes
    expect(innerStore.uploadedSha256[storageKey], crypto.sha256.convert(storedRawBytes).toString());
  });

  test('download retrieves and decrypts ciphertext into original audio bytes', () async {
    final audioFile = File('${tempDir.path}/take.m4a');
    final originalBytes = utf8.encode('Original high quality audio capture');
    await audioFile.writeAsBytes(originalBytes);
    final contentHash = crypto.sha256.convert(originalBytes).toString();

    const storageKey = 'user123/captures/rec2/take.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: contentHash);

    // Download through EncryptedMediaStore
    final decryptedBytes = await encryptedStore.download(storageKey);

    expect(decryptedBytes, equals(originalBytes));
    // The hash of decrypted bytes matches the local recording contentHash!
    expect(crypto.sha256.convert(decryptedBytes).toString(), contentHash);
  });

  test('download with wrong cipher throws E2eeDecryptionException', () async {
    final audioFile = File('${tempDir.path}/private.m4a');
    await audioFile.writeAsBytes(utf8.encode('Secret recording'));
    const storageKey = 'user123/captures/rec3/private.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: 'somehash');

    // Different cipher
    final kdf = E2eeKeyDerivation();
    final otherKey = await kdf.deriveKey(passphrase: 'wrong-password', salt: kdf.generateSalt());
    final badCipher = E2eeCipher(key: otherKey);
    final badStore = EncryptedMediaStore(inner: innerStore, cipher: badCipher);

    expect(() => badStore.download(storageKey), throwsA(isA<E2eeDecryptionException>()));
  });
}

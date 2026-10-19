import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
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
  Stream<List<int>> download(String key, {required int maxBytes}) {
    if (!storage.containsKey(key)) {
      return Stream<List<int>>.error(StateError('Not found: $key'));
    }
    return boundedObjectBytes(
      Stream<List<int>>.value(storage[key]!),
      maxBytes: maxBytes,
    );
  }
}

Future<List<int>> _read(MediaObjectStore store, String key, {int maxBytes = 1 << 20}) async =>
    <int>[for (final List<int> chunk in await store.download(key, maxBytes: maxBytes).toList()) ...chunk];

Future<E2eeCipher> _cipher(String passphrase) async {
  final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: 1000);
  final SecretKey key = await kdf.deriveKey(passphrase: passphrase, salt: kdf.generateSalt());
  return E2eeCipher(key: key);
}

void main() {
  late E2eeCipher cipher;
  late FakeMediaStore innerStore;
  late EncryptedMediaStore encryptedStore;
  late Directory tempDir;

  setUp(() async {
    cipher = await _cipher('audio-encryption-key');
    innerStore = FakeMediaStore();
    encryptedStore = EncryptedMediaStore(inner: innerStore, cipher: cipher, ownerId: 'user123');
    tempDir = await Directory.systemTemp.createTemp('e2ee_media_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('upload encrypts audio file bytes before sending to underlying store', () async {
    final File audioFile = File('${tempDir.path}/sample.m4a');
    final List<int> plainAudioBytes = utf8.encode('RIFF....Simulated audio capture bytes');
    await audioFile.writeAsBytes(plainAudioBytes);
    final String plainSha256 = crypto.sha256.convert(plainAudioBytes).toString();

    const String storageKey = 'user123/captures/rec1/sample.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: plainSha256);

    // Stored bytes in backend are encrypted, NOT plaintext
    expect(innerStore.storage.containsKey(storageKey), isTrue);
    final List<int> storedRawBytes = innerStore.storage[storageKey]!;
    expect(storedRawBytes, isNot(equals(plainAudioBytes)));

    // Uploaded SHA-256 metadata matches ciphertext bytes
    expect(innerStore.uploadedSha256[storageKey], crypto.sha256.convert(storedRawBytes).toString());
  });

  test('download retrieves and decrypts ciphertext into original audio bytes', () async {
    final File audioFile = File('${tempDir.path}/take.m4a');
    final List<int> originalBytes = utf8.encode('Original high quality audio capture');
    await audioFile.writeAsBytes(originalBytes);
    final String contentHash = crypto.sha256.convert(originalBytes).toString();

    const String storageKey = 'user123/captures/rec2/take.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: contentHash);

    // Download through EncryptedMediaStore
    final List<int> decryptedBytes = await _read(encryptedStore, storageKey);

    expect(decryptedBytes, equals(originalBytes));
    // The hash of decrypted bytes matches the local recording contentHash!
    expect(crypto.sha256.convert(decryptedBytes).toString(), contentHash);
  });

  test('the ceiling on the clear bytes maps to one on the envelope', () async {
    final File audioFile = File('${tempDir.path}/bound.m4a');
    final List<int> clear = utf8.encode('Exactly this many bytes');
    await audioFile.writeAsBytes(clear);
    const String storageKey = 'user123/captures/rec4/bound.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: 'h');
    expect(innerStore.storage[storageKey]!.length, clear.length + E2eeCipher.envelopeOverheadBytes);

    expect(await _read(encryptedStore, storageKey, maxBytes: clear.length), clear);
    await expectLater(
      _read(encryptedStore, storageKey, maxBytes: clear.length - 1),
      throwsA(isA<MediaObjectTooLargeException>()),
    );
  });

  test('a blob moved under another key does not open', () async {
    // The server (or anyone with bucket access) copies rec-1's object to
    // rec-2's key. The bytes are intact and the key is right; only the
    // context differs, and that is what the associated data pins.
    final File audioFile = File('${tempDir.path}/moved.m4a');
    await audioFile.writeAsBytes(utf8.encode('Audio of recording one'));
    await encryptedStore.upload('user123/rec-1/a.m4a', audioFile, sha256: 'h');
    innerStore.storage['user123/rec-2/a.m4a'] = innerStore.storage['user123/rec-1/a.m4a']!;

    expect(await _read(encryptedStore, 'user123/rec-1/a.m4a'), utf8.encode('Audio of recording one'));
    expect(
      () => _read(encryptedStore, 'user123/rec-2/a.m4a'),
      throwsA(isA<E2eeDecryptionException>()),
    );
  });

  test('the same key under another owner does not open the blob', () async {
    // Two owners sharing one master key (one person, two accounts): the
    // inner store prefixes the owner folder outside the cipher, so the
    // associated data has to carry it or a copy across folders would open.
    final File audioFile = File('${tempDir.path}/owner.m4a');
    await audioFile.writeAsBytes(utf8.encode('Audio of owner one'));
    await encryptedStore.upload('rec-1/a.m4a', audioFile, sha256: 'h');
    final EncryptedMediaStore otherOwner =
        EncryptedMediaStore(inner: innerStore, cipher: cipher, ownerId: 'user456');

    expect(
      () => _read(otherOwner, 'rec-1/a.m4a'),
      throwsA(isA<E2eeDecryptionException>()),
    );
  });

  test('download with wrong cipher throws E2eeDecryptionException', () async {
    final File audioFile = File('${tempDir.path}/private.m4a');
    await audioFile.writeAsBytes(utf8.encode('Secret recording'));
    const String storageKey = 'user123/captures/rec3/private.m4a';
    await encryptedStore.upload(storageKey, audioFile, sha256: 'somehash');

    // Different cipher
    final E2eeCipher badCipher = await _cipher('wrong-password');
    final EncryptedMediaStore badStore = EncryptedMediaStore(inner: innerStore, cipher: badCipher, ownerId: 'user123');

    expect(() => _read(badStore, storageKey), throwsA(isA<E2eeDecryptionException>()));
  });
}

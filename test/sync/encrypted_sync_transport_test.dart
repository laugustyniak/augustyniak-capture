import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';

import 'fake_sync_transport.dart';

void main() {
  late E2eeCipher cipher;
  late FakeSyncTransport fakeTransport;
  late EncryptedSyncTransport encryptedTransport;

  setUp(() async {
    final kdf = E2eeKeyDerivation();
    final salt = kdf.generateSalt();
    final key = await kdf.deriveKey(passphrase: 'super-secret', salt: salt);
    cipher = E2eeCipher(key: key);
    fakeTransport = FakeSyncTransport();
    encryptedTransport = EncryptedSyncTransport(
      inner: fakeTransport,
      cipher: cipher,
    );
  });

  group('EncryptedSyncTransport push', () {
    test('encrypts recordings sensitive fields into encrypted_payload and clears plaintext', () async {
      final row = <String, Object?>{
        'id': 'rec-1',
        'file_path': 'rec1.m4a',
        'duration_ms': 12000,
        'transcript': 'Private speech to text',
        'title': 'Confidential meeting',
        'summary': 'Summary of secret discussion',
        'tags': ['confidential', 'strategy'],
        'payload': {'priority': 'high', 'custom': 42},
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.recordings, [row]);

      // Inner transport receives encrypted row
      expect(fakeTransport.pushes, hasLength(1));
      final (table, pushedRows) = fakeTransport.pushes.first;
      expect(table, SyncTable.recordings);
      expect(pushedRows, hasLength(1));

      final pushed = pushedRows.first;
      expect(pushed['transcript'], isNull);
      expect(pushed['title'], isNull);
      expect(pushed['summary'], isNull);
      expect(pushed['tags'], isEmpty);
      expect(pushed['payload'], isNull);

      final encPayload = pushed['encrypted_payload'] as String?;
      expect(encPayload, isNotNull);
      expect(E2eeCipher.isSealed(encPayload), isTrue);

      // Decrypting the payload reveals original values
      final clearText = await cipher.unseal(encPayload!);
      final unpacked = jsonDecode(clearText) as Map<String, dynamic>;
      expect(unpacked['transcript'], 'Private speech to text');
      expect(unpacked['title'], 'Confidential meeting');
      expect(unpacked['summary'], 'Summary of secret discussion');
      expect(unpacked['tags'], ['confidential', 'strategy']);
      expect(unpacked['payload'], {'priority': 'high', 'custom': 42});
    });

    test('encrypts segments text and error into encrypted_payload', () async {
      final row = <String, Object?>{
        'recording_id': 'rec-1',
        'index': 0,
        'text': 'Segment transcript part',
        'error': 'Some internal error description',
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.segments, [row]);

      final (_, pushedRows) = fakeTransport.pushes.first;
      final pushed = pushedRows.first;
      expect(pushed['text'], isNull);
      expect(pushed['error'], isNull);

      final encPayload = pushed['encrypted_payload'] as String;
      final clear = await cipher.unseal(encPayload);
      final unpacked = jsonDecode(clear) as Map<String, dynamic>;
      expect(unpacked['text'], 'Segment transcript part');
      expect(unpacked['error'], 'Some internal error description');
    });

    test('encrypts clipboard text, preview and collections', () async {
      final row = <String, Object?>{
        'id': 'clip-1',
        'text': 'Secret clipboard text',
        'preview': 'Secret clip...',
        'collections': ['passwords'],
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.clipboardItems, [row]);

      final (_, pushedRows) = fakeTransport.pushes.first;
      final pushed = pushedRows.first;
      expect(pushed['text'], isNull);
      expect(pushed['preview'], isNull);
      expect(pushed['collections'], isEmpty);

      final encPayload = pushed['encrypted_payload'] as String;
      final clear = await cipher.unseal(encPayload);
      final unpacked = jsonDecode(clear) as Map<String, dynamic>;
      expect(unpacked['text'], 'Secret clipboard text');
      expect(unpacked['preview'], 'Secret clip...');
      expect(unpacked['collections'], ['passwords']);
    });
  });

  group('EncryptedSyncTransport pull', () {
    test('pull unseals encrypted_payload and restores plaintext fields', () async {
      // Simulate remote row stored in fake server table
      final encryptedPayload = await cipher.seal(jsonEncode({
        'transcript': 'Restored transcript',
        'title': 'Restored title',
        'summary': 'Restored summary',
        'tags': ['tag1'],
        'payload': {'notes': 'secret'},
      }));

      fakeTransport.tables[SyncTable.recordings] = {
        'rec-pulled-1': {
          'id': 'rec-pulled-1',
          'file_path': 'rec_p1.m4a',
          'duration_ms': 5000,
          'transcript': null,
          'title': null,
          'summary': null,
          'tags': <String>[],
          'payload': null,
          'encrypted_payload': encryptedPayload,
          'version': 1,
          'updated_at': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
        },
      };

      final page = await encryptedTransport.pull(
        SyncTable.recordings,
        since: null,
        after: null,
        limit: 10,
      );

      expect(page.rows, hasLength(1));
      final pulled = page.rows.first;

      expect(pulled['transcript'], 'Restored transcript');
      expect(pulled['title'], 'Restored title');
      expect(pulled['summary'], 'Restored summary');
      expect(pulled['tags'], ['tag1']);
      expect(pulled['payload'], {'notes': 'secret'});
    });

    test('pull gracefully leaves plaintext row intact if pre-E2EE', () async {
      fakeTransport.tables[SyncTable.recordings] = {
        'rec-legacy-1': {
          'id': 'rec-legacy-1',
          'transcript': 'Old unencrypted transcript',
          'title': 'Old title',
          'version': 1,
          'updated_at': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
        },
      };

      final page = await encryptedTransport.pull(
        SyncTable.recordings,
        since: null,
        after: null,
        limit: 10,
      );

      final pulled = page.rows.first;
      expect(pulled['transcript'], 'Old unencrypted transcript');
      expect(pulled['title'], 'Old title');
    });
  });
}

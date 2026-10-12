import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/sync/data/encrypted_sync_transport.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_cipher.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';

import 'fake_sync_transport.dart';

class _RecordingLogSink implements LogSink {
  final List<(LogLevel, String)> lines = <(LogLevel, String)>[];

  @override
  void log(String message, {LogLevel level = LogLevel.info, String? recordingId}) {
    lines.add((level, message));
  }
}

const String _owner = 'owner-a';

/// The transport's context, spelled out by hand: length-prefixed parts,
/// newline-joined — owner, table, then each key column value.
List<int> _aad(SyncTable table, List<String> keyParts) => utf8.encode(
      <String>[_owner, table.serverName, ...keyParts]
          .map((String part) => '${part.length}:$part')
          .join('\n'),
    );

String _past() =>
    DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();

void main() {
  late E2eeCipher cipher;
  late FakeSyncTransport fakeTransport;
  late _RecordingLogSink log;
  late EncryptedSyncTransport encryptedTransport;

  setUp(() async {
    final E2eeKeyDerivation kdf = E2eeKeyDerivation(iterations: 1000);
    final List<int> salt = kdf.generateSalt();
    final SecretKey key = await kdf.deriveKey(passphrase: 'super-secret', salt: salt);
    cipher = E2eeCipher(key: key);
    fakeTransport = FakeSyncTransport();
    log = _RecordingLogSink();
    encryptedTransport = EncryptedSyncTransport(
      inner: fakeTransport,
      cipher: cipher,
      ownerId: _owner,
      log: log,
    );
  });

  Future<SyncPage> pullAll(SyncTable table) => encryptedTransport.pull(
        table,
        since: null,
        after: null,
        limit: 10,
      );

  group('EncryptedSyncTransport push', () {
    test('encrypts recordings sensitive fields into encrypted_payload and clears plaintext', () async {
      final Map<String, Object?> row = <String, Object?>{
        'id': 'rec-1',
        'file_path': 'rec1.m4a',
        'duration_ms': 12000,
        'transcript': 'Private speech to text',
        'title': 'Confidential meeting',
        'summary': 'Summary of secret discussion',
        'tags': <String>['confidential', 'strategy'],
        'payload': <String, Object?>{'priority': 'high', 'custom': 42},
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.recordings, <Map<String, Object?>>[row]);

      // Inner transport receives encrypted row
      expect(fakeTransport.pushes, hasLength(1));
      final (SyncTable table, List<Map<String, Object?>> pushedRows) = fakeTransport.pushes.first;
      expect(table, SyncTable.recordings);
      expect(pushedRows, hasLength(1));

      final Map<String, Object?> pushed = pushedRows.first;
      expect(pushed['transcript'], isNull);
      expect(pushed['title'], isNull);
      expect(pushed['summary'], isNull);
      expect(pushed['tags'], isEmpty);
      expect(pushed['payload'], isNull);

      final String? encPayload = pushed['encrypted_payload'] as String?;
      expect(encPayload, isNotNull);
      expect(E2eeCipher.isSealed(encPayload), isTrue);

      // Decrypting the payload under the row's own context reveals the values
      final String clearText = await cipher.unseal(encPayload!, aad: _aad(SyncTable.recordings, <String>['rec-1']));
      final Map<String, dynamic> unpacked = jsonDecode(clearText) as Map<String, dynamic>;
      expect(unpacked['transcript'], 'Private speech to text');
      expect(unpacked['title'], 'Confidential meeting');
      expect(unpacked['summary'], 'Summary of secret discussion');
      expect(unpacked['tags'], <String>['confidential', 'strategy']);
      expect(unpacked['payload'], <String, Object?>{'priority': 'high', 'custom': 42});
    });

    test('encrypts segments text and error into encrypted_payload', () async {
      final Map<String, Object?> row = <String, Object?>{
        'recording_id': 'rec-1',
        'index': 0,
        'text': 'Segment transcript part',
        'error': 'Some internal error description',
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.segments, <Map<String, Object?>>[row]);

      final (_, List<Map<String, Object?>> pushedRows) = fakeTransport.pushes.first;
      final Map<String, Object?> pushed = pushedRows.first;
      expect(pushed['text'], isNull);
      expect(pushed['error'], isNull);

      final String encPayload = pushed['encrypted_payload'] as String;
      final String clear = await cipher.unseal(encPayload, aad: _aad(SyncTable.segments, <String>['rec-1', '0']));
      final Map<String, dynamic> unpacked = jsonDecode(clear) as Map<String, dynamic>;
      expect(unpacked['text'], 'Segment transcript part');
      expect(unpacked['error'], 'Some internal error description');
    });

    test('encrypts clipboard text, preview and collections', () async {
      final Map<String, Object?> row = <String, Object?>{
        'id': 'clip-1',
        'text': 'Secret clipboard text',
        'preview': 'Secret clip...',
        'collections': <String>['passwords'],
        'version': 1,
      };

      await encryptedTransport.push(SyncTable.clipboardItems, <Map<String, Object?>>[row]);

      final (_, List<Map<String, Object?>> pushedRows) = fakeTransport.pushes.first;
      final Map<String, Object?> pushed = pushedRows.first;
      expect(pushed['text'], isNull);
      expect(pushed['preview'], isNull);
      expect(pushed['collections'], isEmpty);

      final String encPayload = pushed['encrypted_payload'] as String;
      final String clear = await cipher.unseal(encPayload, aad: _aad(SyncTable.clipboardItems, <String>['clip-1']));
      final Map<String, dynamic> unpacked = jsonDecode(clear) as Map<String, dynamic>;
      expect(unpacked['text'], 'Secret clipboard text');
      expect(unpacked['preview'], 'Secret clip...');
      expect(unpacked['collections'], <String>['passwords']);
    });

    test('encrypts a revision\'s old and new value', () async {
      // Regression: revisions went out in the clear, so every hand edit put
      // the transcript, title or summary on the server twice.
      final Map<String, Object?> row = <String, Object?>{
        'recording_id': 'rec-1',
        'at': '2026-10-06T10:00:00.000Z',
        'field': 'transcript',
        'from_value': 'Old private transcript',
        'to_value': 'New private transcript',
        'source': 'user',
      };

      await encryptedTransport.push(SyncTable.revisions, <Map<String, Object?>>[row]);

      final (_, List<Map<String, Object?>> pushedRows) = fakeTransport.pushes.first;
      final Map<String, Object?> pushed = pushedRows.first;
      expect(pushed['from_value'], isNull);
      expect(pushed['to_value'], isNull);
      expect(pushed['source'], 'user');
      expect(jsonEncode(pushed), isNot(contains('private transcript')));

      final String encPayload = pushed['encrypted_payload'] as String;
      final String clear = await cipher.unseal(
        encPayload,
        aad: _aad(SyncTable.revisions, <String>['rec-1', '2026-10-06T10:00:00.000Z', 'transcript']),
      );
      final Map<String, dynamic> unpacked = jsonDecode(clear) as Map<String, dynamic>;
      expect(unpacked['from_value'], 'Old private transcript');
      expect(unpacked['to_value'], 'New private transcript');
    });
  });

  group('EncryptedSyncTransport pull', () {
    test('pull unseals encrypted_payload, restores plaintext fields and drops the envelope', () async {
      // Simulate remote row stored in fake server table
      final String encryptedPayload = await cipher.seal(
        jsonEncode(<String, Object?>{
          'transcript': 'Restored transcript',
          'title': 'Restored title',
          'summary': 'Restored summary',
          'tags': <String>['tag1'],
          'payload': <String, Object?>{'notes': 'secret'},
        }),
        aad: _aad(SyncTable.recordings, <String>['rec-pulled-1']),
      );

      fakeTransport.tables[SyncTable.recordings] = <String, Map<String, Object?>>{
        'rec-pulled-1': <String, Object?>{
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
          'updated_at': _past(),
        },
      };

      final SyncPage page = await pullAll(SyncTable.recordings);

      expect(page.rows, hasLength(1));
      final Map<String, Object?> pulled = page.rows.first;

      expect(pulled['transcript'], 'Restored transcript');
      expect(pulled['title'], 'Restored title');
      expect(pulled['summary'], 'Restored summary');
      expect(pulled['tags'], <String>['tag1']);
      expect(pulled['payload'], <String, Object?>{'notes': 'secret'});
      expect(pulled.containsKey('encrypted_payload'), isFalse);
      expect(log.lines, isEmpty);
    });

    test('a revision pushed in Dart\'s timestamp shape opens in Postgres\'s', () async {
      // The fake hands `at` back as `+00:00`, the way PostgREST does, while
      // the push bound the envelope to the `.000Z` string. Both must map to
      // the same associated data or no revision would ever open.
      await encryptedTransport.push(SyncTable.revisions, <Map<String, Object?>>[
        <String, Object?>{
          'recording_id': 'rec-1',
          'at': '2026-10-06T10:00:00.000Z',
          'field': 'title',
          'from_value': 'Old title',
          'to_value': 'New title',
          'source': 'user',
        },
      ]);
      fakeTransport.clock = () => DateTime.now().toUtc().add(const Duration(minutes: 5));

      final SyncPage page = await pullAll(SyncTable.revisions);

      expect(page.rows, hasLength(1));
      final Map<String, Object?> pulled = page.rows.first;
      expect(pulled['at'], '2026-10-06T10:00:00+00:00');
      expect(pulled['from_value'], 'Old title');
      expect(pulled['to_value'], 'New title');
      expect(pulled.containsKey('encrypted_payload'), isFalse);
      expect(SyncRowCodec.revisionFromRow(pulled)?.to, 'New title');
    });

    test('pull gracefully leaves plaintext row intact if pre-E2EE', () async {
      fakeTransport.tables[SyncTable.recordings] = <String, Map<String, Object?>>{
        'rec-legacy-1': <String, Object?>{
          'id': 'rec-legacy-1',
          'transcript': 'Old unencrypted transcript',
          'title': 'Old title',
          'version': 1,
          'updated_at': _past(),
        },
      };

      final SyncPage page = await pullAll(SyncTable.recordings);

      final Map<String, Object?> pulled = page.rows.first;
      expect(pulled['transcript'], 'Old unencrypted transcript');
      expect(pulled['title'], 'Old title');
    });

    test('an envelope transplanted onto another row stays sealed, is logged and is not decodable', () async {
      final String forRec1 = await cipher.seal(
        jsonEncode(<String, Object?>{'title': 'Belongs to rec-1', 'transcript': 't'}),
        aad: _aad(SyncTable.recordings, <String>['rec-1']),
      );
      fakeTransport.tables[SyncTable.recordings] = <String, Map<String, Object?>>{
        'rec-2': <String, Object?>{
          'id': 'rec-2',
          'file_path': 'rec2.m4a',
          'duration_ms': 1,
          'type': 'audioRecording',
          'status': 'completed',
          'created_at': '2026-10-06T10:00:00.000Z',
          'title': null,
          'transcript': null,
          'encrypted_payload': forRec1,
          'version': 1,
          'updated_at': _past(),
        },
      };

      final SyncPage page = await pullAll(SyncTable.recordings);

      // The row is still in the page — keyset paging continues after it.
      expect(page.rows, hasLength(1));
      final Map<String, Object?> pulled = page.rows.first;
      expect(pulled['title'], isNull, reason: 'rec-1 content must not land on rec-2');
      expect(pulled['encrypted_payload'], forRec1, reason: 'left sealed, not blanked');
      // The codec refuses it, which the engine counts as a skip.
      expect(SyncRowCodec.recordingFromRow(pulled), isNull);
      expect(log.lines, hasLength(1));
      expect(log.lines.single.$1, LogLevel.warn);
      expect(log.lines.single.$2, contains('recordings row rec-2'));
      expect(log.lines.single.$2, contains('could not be decrypted'));
    });

    test('an envelope sealed by another owner stays sealed', () async {
      final EncryptedSyncTransport otherOwner = EncryptedSyncTransport(
        inner: fakeTransport,
        cipher: cipher,
        ownerId: 'owner-b',
      );
      await otherOwner.push(SyncTable.projects, <Map<String, Object?>>[
        <String, Object?>{
          'id': 'proj-1',
          'name': 'Shared name',
          'repository_path': '/home/b/secret',
          'version': 1,
        },
      ]);
      fakeTransport.clock = () => DateTime.now().toUtc().add(const Duration(minutes: 5));

      final SyncPage page = await pullAll(SyncTable.projects);

      final Map<String, Object?> pulled = page.rows.single;
      expect(pulled['repository_path'], isNull);
      expect(E2eeCipher.isSealed(pulled['encrypted_payload'] as String?), isTrue);
      expect(SyncRowCodec.projectFromRow(pulled), isNull);
      expect(log.lines, hasLength(1));
    });

    test('a corrupt envelope stays sealed and is logged once', () async {
      fakeTransport.tables[SyncTable.clipboardItems] = <String, Map<String, Object?>>{
        'clip-1': <String, Object?>{
          'id': 'clip-1',
          'type': 'text',
          'copied_at': '2026-10-06T10:00:00.000Z',
          'text': null,
          'encrypted_payload': 'enc:v2:not-base64!!',
          'version': 1,
          'updated_at': _past(),
        },
      };

      final SyncPage page = await pullAll(SyncTable.clipboardItems);

      final Map<String, Object?> pulled = page.rows.single;
      expect(pulled['text'], isNull);
      expect(pulled['encrypted_payload'], 'enc:v2:not-base64!!');
      expect(SyncRowCodec.clipboardItemFromRow(pulled), isNull);
      expect(log.lines, hasLength(1));
    });

    test('a conflict row the server returns is unsealed the same way', () async {
      // Seed the server at version 2 under this owner, then push version 1:
      // the conflict comes back sealed and must open for the engine.
      await encryptedTransport.push(SyncTable.recordings, <Map<String, Object?>>[
        <String, Object?>{
          'id': 'rec-c',
          'file_path': 'c.m4a',
          'duration_ms': 1,
          'title': 'Server title',
          'version': 2,
        },
      ]);
      final SyncPushResult result = await encryptedTransport.push(SyncTable.recordings, <Map<String, Object?>>[
        <String, Object?>{
          'id': 'rec-c',
          'file_path': 'c.m4a',
          'duration_ms': 1,
          'title': 'Stale title',
          'version': 1,
        },
      ]);

      expect(result.applied, 0);
      expect(result.conflicts, hasLength(1));
      expect(result.conflicts.single['title'], 'Server title');
      expect(result.conflicts.single.containsKey('encrypted_payload'), isFalse);
    });
  });
}

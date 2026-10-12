import 'dart:convert';

import '../../logs/domain/log_event.dart';
import '../domain/e2ee_cipher.dart';
import '../domain/sync_row_codec.dart';
import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';

/// Decorator around [SyncTransport] that seals a row's sensitive columns
/// into `encrypted_payload` on push and opens them again on pull.
///
/// Sensitive fields (transcripts, titles, summaries, tags, custom payload,
/// segment text, clipboard text, a revision's old and new value) are packed
/// into one AES-256-GCM envelope per row and the cleartext columns go out
/// null, so Postgres stores no content at all.
///
/// **Every envelope is bound to the row it belongs to.** The associated data
/// names the owner, the table and every key column of the row, each part
/// length-prefixed so no two contexts spell the same bytes, so a server that
/// copies an envelope
/// from one row, table or owner to another produces a row that fails to
/// open rather than one that decrypts into the wrong place. [ownerId] is the
/// signed-in user's id as this device knows it — never read off the row,
/// which is the server's word.
///
/// **A row that fails to open stays sealed.** `_unsealRow` leaves
/// `encrypted_payload` in place and logs once; it never applies a row whose
/// content columns are null, because that would turn a corrupt or
/// transplanted envelope into a local edit that blanks the capture's
/// metadata. `SyncRowCodec` refuses any row that still carries an envelope,
/// which makes the engine count it as a codec skip: the row stays in the
/// page (keyset paging continues after it as normal) and the cursor holds at
/// its `updated_at`, so it is re-offered on every run until a key that opens
/// it arrives. Dropping the row here instead would break paging — the engine
/// continues after the *last row of the page it was handed*.
class EncryptedSyncTransport implements SyncTransport {
  EncryptedSyncTransport({
    required SyncTransport inner,
    required E2eeCipher cipher,
    required String ownerId,
    LogSink log = const NoopLogSink(),
  })  : _inner = inner,
        _cipher = cipher,
        _ownerId = ownerId,
        _log = log;

  final SyncTransport _inner;
  final E2eeCipher _cipher;
  final String _ownerId;
  final LogSink _log;

  @override
  Future<DateTime> serverNow() => _inner.serverNow();

  @override
  Future<SyncPushResult> push(
    SyncTable table,
    List<Map<String, Object?>> rows,
  ) async {
    final List<Map<String, Object?>> encryptedRows = <Map<String, Object?>>[];
    for (final Map<String, Object?> row in rows) {
      encryptedRows.add(await _sealRow(table, Map<String, Object?>.from(row)));
    }
    final SyncPushResult result = await _inner.push(table, encryptedRows);

    // Unseal any conflicts returned by the server so the engine can resolve
    final List<Map<String, Object?>> unsealedConflicts = <Map<String, Object?>>[];
    for (final Map<String, Object?> conflict in result.conflicts) {
      unsealedConflicts.add(await _unsealRow(table, Map<String, Object?>.from(conflict)));
    }

    return SyncPushResult(
      applied: result.applied,
      conflicts: unsealedConflicts,
      rejected: result.rejected,
    );
  }

  @override
  Future<SyncPage> pull(
    SyncTable table, {
    required DateTime? since,
    required Map<String, Object?>? after,
    required int limit,
  }) async {
    final SyncPage page = await _inner.pull(
      table,
      since: since,
      after: after,
      limit: limit,
    );

    final List<Map<String, Object?>> decryptedRows = <Map<String, Object?>>[];
    for (final Map<String, Object?> row in page.rows) {
      decryptedRows.add(await _unsealRow(table, Map<String, Object?>.from(row)));
    }

    return SyncPage(
      rows: decryptedRows,
      hasMore: page.hasMore,
    );
  }

  /// The context an envelope is valid in: owner id, table name, then each
  /// key column's value in `SyncTable.keyColumns` order. Every part is
  /// written as `<length>:<value>` and the parts are newline-joined, so a
  /// value that itself contains a separator cannot make two different rows
  /// read as one context. A timestamp key column (`revisions.at`) is parsed
  /// and re-encoded first: the device pushes Dart's `.000Z` shape and
  /// Postgres hands back `+00:00`, and the two must bind to the same bytes
  /// or no revision would ever open on pull.
  List<int> _aad(SyncTable table, Map<String, Object?> row) {
    final Iterable<String> parts = <String>[
      _ownerId,
      table.serverName,
      for (final String column in table.keyColumns) _keyPart(column, row[column]),
    ].map((String part) => '${part.length}:$part');
    return utf8.encode(parts.join('\n'));
  }

  static String _keyPart(String column, Object? value) {
    if (column == 'at' && value is String) {
      final DateTime? at = DateTime.tryParse(value);
      if (at != null) return at.toUtc().toIso8601String();
    }
    return '$value';
  }

  Future<Map<String, Object?>> _sealRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    switch (table) {
      case SyncTable.recordings:
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('transcript')) 'transcript': row['transcript'],
          if (row.containsKey('title')) 'title': row['title'],
          if (row.containsKey('summary')) 'summary': row['summary'],
          if (row.containsKey('tags')) 'tags': row['tags'],
          if (row.containsKey('payload')) 'payload': row['payload'],
          if (row.containsKey('category')) 'category': row['category'],
        };
        row['encrypted_payload'] = await _seal(table, row, sensitive);
        row['transcript'] = null;
        row['title'] = null;
        row['summary'] = null;
        row['tags'] = const <String>[];
        row['payload'] = null;
        return row;

      case SyncTable.segments:
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('text')) 'text': row['text'],
          if (row.containsKey('error')) 'error': row['error'],
        };
        row['encrypted_payload'] = await _seal(table, row, sensitive);
        row['text'] = null;
        row['error'] = null;
        return row;

      case SyncTable.clipboardItems:
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('text')) 'text': row['text'],
          if (row.containsKey('preview')) 'preview': row['preview'],
          if (row.containsKey('collections')) 'collections': row['collections'],
        };
        row['encrypted_payload'] = await _seal(table, row, sensitive);
        row['text'] = null;
        row['preview'] = null;
        row['collections'] = const <String>[];
        return row;

      case SyncTable.projects:
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('repository_path'))
            'repository_path': row['repository_path'],
          if (row.containsKey('payload')) 'payload': row['payload'],
        };
        row['encrypted_payload'] = await _seal(table, row, sensitive);
        row['repository_path'] = null;
        row['payload'] = null;
        return row;

      case SyncTable.revisions:
        // The old and new value of a hand edit are the transcript, title or
        // summary at two points in time — the same content the recordings
        // envelope exists for, and the one place it would otherwise sit on
        // the server in the clear.
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('from_value')) 'from_value': row['from_value'],
          if (row.containsKey('to_value')) 'to_value': row['to_value'],
        };
        row['encrypted_payload'] = await _seal(table, row, sensitive);
        row['from_value'] = null;
        row['to_value'] = null;
        return row;

      case SyncTable.devices:
      case SyncTable.syncState:
        return row;
    }
  }

  Future<String> _seal(
    SyncTable table,
    Map<String, Object?> row,
    Map<String, Object?> sensitive,
  ) =>
      _cipher.seal(jsonEncode(sensitive), aad: _aad(table, row));

  Future<Map<String, Object?>> _unsealRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    final Object? encPayload = row['encrypted_payload'];
    if (encPayload is! String || !E2eeCipher.isSealed(encPayload)) {
      return row; // Pre-E2EE legacy row or table without encryption
    }

    try {
      final String clear = await _cipher.unseal(
        encPayload,
        aad: _aad(table, row),
      );
      final Object? decoded = jsonDecode(clear);
      if (decoded is! Map<String, dynamic>) {
        throw const E2eeDecryptionException('Envelope is not a JSON object');
      }
      for (final MapEntry<String, dynamic> entry in decoded.entries) {
        row[entry.key] = entry.value;
      }
      // Opened: the envelope has done its job, and a row still carrying one
      // is the codec's signal that it was *not* opened.
      row.remove('encrypted_payload');
    } on E2eeDecryptionException catch (error) {
      _log.log(
        'Sync: ${table.serverName} row ${SyncRowCodec.rowId(table, row)} '
        'could not be decrypted and was skipped: ${error.message}',
        level: LogLevel.warn,
      );
    } on FormatException catch (error) {
      _log.log(
        'Sync: ${table.serverName} row ${SyncRowCodec.rowId(table, row)} '
        'decrypted to malformed JSON and was skipped: ${error.message}',
        level: LogLevel.warn,
      );
    }
    return row;
  }
}

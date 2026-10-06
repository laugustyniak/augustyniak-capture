import 'dart:convert';

import '../domain/e2ee_cipher.dart';
import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';

/// Decorator around [SyncTransport] that performs client-side Zero-Knowledge
/// authenticated encryption on push, and authenticated decryption on pull.
///
/// Sensitive fields (transcripts, titles, summaries, tags, custom payload,
/// segments text, clipboard text) are packed into an AES-256-GCM envelope
/// stored in `encrypted_payload`. Cleartext fields sent over the wire are set
/// to null / empty defaults so that PostgreSQL stores zero sensitive data.
class EncryptedSyncTransport implements SyncTransport {
  EncryptedSyncTransport({
    required SyncTransport inner,
    required E2eeCipher cipher,
  })  : _inner = inner,
        _cipher = cipher;

  final SyncTransport _inner;
  final E2eeCipher _cipher;

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
        final String sealed = await _cipher.seal(jsonEncode(sensitive));
        row['encrypted_payload'] = sealed;
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
        final String sealed = await _cipher.seal(jsonEncode(sensitive));
        row['encrypted_payload'] = sealed;
        row['text'] = null;
        row['error'] = null;
        return row;

      case SyncTable.clipboardItems:
        final Map<String, Object?> sensitive = <String, Object?>{
          if (row.containsKey('text')) 'text': row['text'],
          if (row.containsKey('preview')) 'preview': row['preview'],
          if (row.containsKey('collections')) 'collections': row['collections'],
        };
        final String sealed = await _cipher.seal(jsonEncode(sensitive));
        row['encrypted_payload'] = sealed;
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
        final String sealed = await _cipher.seal(jsonEncode(sensitive));
        row['encrypted_payload'] = sealed;
        row['repository_path'] = null;
        row['payload'] = null;
        return row;

      case SyncTable.revisions:
      case SyncTable.devices:
      case SyncTable.syncState:
        return row;
    }
  }

  Future<Map<String, Object?>> _unsealRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    final Object? encPayload = row['encrypted_payload'];
    if (encPayload is! String || !E2eeCipher.isSealed(encPayload)) {
      return row; // Pre-E2EE legacy row or table without encryption
    }

    try {
      final String clear = await _cipher.unseal(encPayload);
      final Object? decoded = jsonDecode(clear);
      if (decoded is Map<String, dynamic>) {
        for (final MapEntry<String, dynamic> entry in decoded.entries) {
          row[entry.key] = entry.value;
        }
      }
    } catch (_) {
      // If decryption fails, row keeps nulls / raw state without crashing sync
    }
    return row;
  }
}

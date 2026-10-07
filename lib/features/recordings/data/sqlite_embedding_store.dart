import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../domain/related_captures.dart';

/// Vectors in the app database (#272). Device-local and derived: not in the
/// backup archive, not synced, and dropping the table loses nothing a rebuild
/// cannot restore.
class SqliteEmbeddingStore implements EmbeddingStore {
  SqliteEmbeddingStore(this._db);

  final Database _db;

  /// Kept here, like `UsageRepository.createTable`, so tests build the schema
  /// against an in-memory database. `AppDatabase._initTables()` calls this.
  static void createTable(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS capture_embeddings (
        capture_id TEXT NOT NULL,
        model TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        vector BLOB NOT NULL,
        PRIMARY KEY (capture_id, model)
      );
    ''');
  }

  @override
  Map<String, StoredEmbedding> load(String model) {
    final Map<String, StoredEmbedding> found = <String, StoredEmbedding>{};
    final ResultSet rows = _db.select(
      'SELECT capture_id, fingerprint, vector FROM capture_embeddings '
      'WHERE model = ?',
      <Object?>[model],
    );
    for (final Row row in rows) {
      // One unreadable row costs that row, never the rest — degrade on load.
      final Object? blob = row['vector'];
      if (blob is! Uint8List || blob.isEmpty || blob.length % 4 != 0) continue;
      final String id = row['capture_id'] as String;
      found[id] = StoredEmbedding(
        captureId: id,
        fingerprint: row['fingerprint'] as String,
        model: model,
        // Copied first: the driver's bytes need not start on a 4-byte
        // boundary, and a Float32 view over them would throw.
        vector: Float32List.view(Uint8List.fromList(blob).buffer),
      );
    }
    return found;
  }

  @override
  void put(StoredEmbedding embedding) {
    _db.execute(
      'INSERT OR REPLACE INTO capture_embeddings '
      '(capture_id, model, fingerprint, vector) VALUES (?, ?, ?, ?)',
      <Object?>[
        embedding.captureId,
        embedding.model,
        embedding.fingerprint,
        embedding.vector.buffer.asUint8List(
          embedding.vector.offsetInBytes,
          embedding.vector.lengthInBytes,
        ),
      ],
    );
  }

  @override
  void remove(String captureId) {
    _db.execute(
      'DELETE FROM capture_embeddings WHERE capture_id = ?',
      <Object?>[captureId],
    );
  }
}

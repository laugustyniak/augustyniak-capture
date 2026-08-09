import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
import '../domain/clipboard_item.dart';
import 'clipboard_repository.dart';

class SqliteClipboardRepository implements ClipboardRepository {
  SqliteClipboardRepository({this.maxItems = 100000});

  final int maxItems;
  AppDatabase? _appDatabase;
  List<ClipboardItem> _items = <ClipboardItem>[];

  @override
  List<ClipboardItem> get items => List<ClipboardItem>.unmodifiable(_items);

  @override
  Set<String> get allCollections {
    final Set<String> collections = <String>{};
    for (final ClipboardItem item in _items) {
      collections.addAll(item.collections);
    }
    return collections;
  }

  @override
  Future<void> initialize() async {
    _appDatabase = await AppDatabase.getInstance();
    await _appDatabase!.migrateFromLegacyJsonIfNeeded();
    await getItems();
  }

  @override
  Future<List<ClipboardItem>> getItems() async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    final ResultSet results = db.rawDb.select('''
      SELECT id, type, text, image_path, copied_at, preview, collections_json
      FROM clipboard_items
      ORDER BY copied_at DESC
      LIMIT ?;
    ''', <Object?>[maxItems]);

    final List<ClipboardItem> loaded = <ClipboardItem>[];
    for (final Row row in results) {
      final List<dynamic> collectionsRaw =
          jsonDecode(row['collections_json'] as String? ?? '[]') as List<dynamic>;
      final Set<String> collections =
          collectionsRaw.map((dynamic e) => e.toString()).toSet();

      final String typeStr = row['type'] as String? ?? 'text';
      final ClipboardItemType type = typeStr == 'image'
          ? ClipboardItemType.image
          : ClipboardItemType.text;

      loaded.add(
        ClipboardItem(
          id: row['id'] as String,
          type: type,
          text: row['text'] as String?,
          imagePath: row['image_path'] as String?,
          copiedAt: DateTime.fromMillisecondsSinceEpoch(row['copied_at'] as int),
          preview: row['preview'] as String?,
          collections: collections,
        ),
      );
    }

    _items = loaded;
    return _items;
  }

  @override
  Future<void> addItem(ClipboardItem item) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    if (_items.isNotEmpty) {
      final ClipboardItem latest = _items.first;
      if (item.type == latest.type &&
          item.text == latest.text &&
          item.imagePath == latest.imagePath) {
        return;
      }
    }

    db.rawDb.execute('''
      INSERT OR REPLACE INTO clipboard_items 
      (id, type, text, image_path, copied_at, preview, collections_json)
      VALUES (?, ?, ?, ?, ?, ?, ?);
    ''', <Object?>[
      item.id,
      item.type == ClipboardItemType.image ? 'image' : 'text',
      item.text,
      item.imagePath,
      item.copiedAt.millisecondsSinceEpoch,
      item.preview,
      jsonEncode(item.collections.toList()),
    ]);

    // Read the rows about to fall off the end *before* deleting them: an image
    // item owns a PNG on disk, and a bare `DELETE` drops the only record of
    // where that file is. `deleteItem` and `clearHistory` both take the file
    // with the row, and eviction has to as well or the images directory grows
    // for the rest of the install's life with nothing able to name the strays —
    // there is no orphan sweep here, unlike the recordings directory.
    final ResultSet evicted = db.rawDb.select('''
      SELECT image_path FROM clipboard_items
      WHERE image_path IS NOT NULL
        AND id NOT IN (
          SELECT id FROM clipboard_items ORDER BY copied_at DESC LIMIT ?
        );
    ''', <Object?>[maxItems]);

    db.rawDb.execute('''
      DELETE FROM clipboard_items
      WHERE id NOT IN (
        SELECT id FROM clipboard_items ORDER BY copied_at DESC LIMIT ?
      );
    ''', <Object?>[maxItems]);

    // Files after the row, not before: a delete that fails leaves a file with
    // no row — invisible but harmless — while the other order would leave a row
    // pointing at a file that is gone, which every reader would treat as a
    // broken entry. Same ordering rule the recordings delete follows, inverted
    // for the same reason it is stated there.
    for (final Row row in evicted) {
      await _deleteImage(row['image_path'] as String?);
    }

    await getItems();
  }

  /// Best-effort: a PNG that cannot be removed costs disk space, never the
  /// history operation that was asked for.
  Future<void> _deleteImage(String? path) async {
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> updateItemText(String id, String text) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    if (text.trim().isEmpty) return;

    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;
    if (_items[index].type != ClipboardItemType.text) return;

    // copied_at is deliberately untouched: getItems() reads
    // ORDER BY copied_at DESC, so the entry keeps its place in the list.
    db.rawDb.execute(
      'UPDATE clipboard_items SET text = ?, preview = ? WHERE id = ?;',
      <Object?>[text, ClipboardItem.previewFor(text), id],
    );

    await getItems();
  }

  @override
  Future<void> toggleItemCollection(String id, String collectionName) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    if (index == -1) return;

    final ClipboardItem item = _items[index];
    final Set<String> collections = Set<String>.from(item.collections);
    if (collections.contains(collectionName)) {
      collections.remove(collectionName);
    } else {
      collections.add(collectionName);
    }

    db.rawDb.execute('''
      UPDATE clipboard_items
      SET collections_json = ?
      WHERE id = ?;
    ''', <Object?>[jsonEncode(collections.toList()), id]);

    await getItems();
  }

  @override
  Future<void> deleteItem(String id) async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    final int index = _items.indexWhere((ClipboardItem item) => item.id == id);
    final String? imagePath = index == -1 ? null : _items[index].imagePath;

    db.rawDb.execute('DELETE FROM clipboard_items WHERE id = ?;', <Object?>[id]);
    await _deleteImage(imagePath);
    await getItems();
  }

  @override
  Future<void> clearHistory() async {
    final AppDatabase db = _appDatabase ?? await AppDatabase.getInstance();
    final List<String?> images = _items
        .map((ClipboardItem item) => item.imagePath)
        .toList();

    db.rawDb.execute('DELETE FROM clipboard_items;');
    _items.clear();
    for (final String? path in images) {
      await _deleteImage(path);
    }
  }
}

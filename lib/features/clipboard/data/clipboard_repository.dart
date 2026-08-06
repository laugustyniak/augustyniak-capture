import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/clipboard_item.dart';

typedef ClipboardStorageDirectoryProvider = Future<Directory> Function();

abstract class ClipboardRepository {
  List<ClipboardItem> get items;
  Set<String> get allCollections;

  Future<void> initialize();
  Future<List<ClipboardItem>> getItems();
  Future<void> addItem(ClipboardItem item);
  Future<void> toggleItemCollection(String id, String collectionName);
  Future<void> deleteItem(String id);
  Future<void> clearHistory();
}

class LocalJsonClipboardRepository implements ClipboardRepository {
  LocalJsonClipboardRepository({
    this.maxItems = 100,
    ClipboardStorageDirectoryProvider? storageDirectoryProvider,
  }) : _storageDirectoryProvider =
           storageDirectoryProvider ?? _defaultStorageDirectory;

  static const MethodChannel _nativeChannel = MethodChannel(
    'ai.augustyniak.capture/clipboard',
  );

  final int maxItems;
  final ClipboardStorageDirectoryProvider _storageDirectoryProvider;
  List<ClipboardItem> _items = <ClipboardItem>[];
  bool _initialized = false;
  File? _dataFile;

  @override
  List<ClipboardItem> get items => List<ClipboardItem>.unmodifiable(_items);

  @override
  Set<String> get allCollections {
    final Set<String> set = <String>{};
    for (final ClipboardItem item in _items) {
      set.addAll(item.collections);
    }
    return set;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final Directory appDir = await _storageDirectoryProvider();
      if (!await appDir.exists()) {
        await appDir.create(recursive: true);
      }
      _dataFile = File(p.join(appDir.path, 'clipboard_history.json'));

      if (await _dataFile!.exists()) {
        final String rawJson = await _dataFile!.readAsString();
        if (rawJson.trim().isNotEmpty) {
          final Object? decoded = jsonDecode(rawJson);
          if (decoded is List) {
            _items = decoded
                .whereType<Map<String, dynamic>>()
                .map(
                  (Map<String, dynamic> json) => ClipboardItem.fromJson(json),
                )
                .toList();
          }
        }
      }
    } catch (_) {
      final File? unreadable = _dataFile;
      if (unreadable != null && await unreadable.exists()) {
        try {
          await unreadable.copy(
            '${unreadable.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
          );
        } catch (_) {
          // Loading still degrades to an empty history if even backup fails.
        }
      }
      _items = <ClipboardItem>[];
    }
    _initialized = true;
  }

  static Future<Directory> _defaultStorageDirectory() async {
    try {
      final String? nativePath = await _nativeChannel.invokeMethod<String>(
        'getClipboardHistoryDirectory',
      );
      if (nativePath != null && nativePath.trim().isNotEmpty) {
        return Directory(nativePath);
      }
    } on PlatformException {
      // Unsupported native bridges use the regular app documents directory.
    } on MissingPluginException {
      // Expected in unit tests and on platforms without a native bridge.
    }

    final Directory directory = await getApplicationDocumentsDirectory();
    return Directory(p.join(directory.path, 'AugustyniakCapture'));
  }

  @override
  Future<List<ClipboardItem>> getItems() async {
    if (!_initialized) await initialize();
    return items;
  }

  @override
  Future<void> addItem(ClipboardItem item) async {
    if (!_initialized) await initialize();

    // Avoid duplicate adjacent items with same content
    if (_items.isNotEmpty) {
      final ClipboardItem latest = _items.first;
      if (latest.type == item.type &&
          latest.text == item.text &&
          latest.imagePath == item.imagePath) {
        return;
      }
    }

    _items.insert(0, item);

    if (_items.length > maxItems) {
      final List<ClipboardItem> removed = _items.sublist(maxItems);
      _items = _items.sublist(0, maxItems);

      // Clean up orphaned images
      for (final ClipboardItem item in removed) {
        if (item.imagePath != null) {
          try {
            final File imageFile = File(item.imagePath!);
            if (await imageFile.exists()) {
              await imageFile.delete();
            }
          } catch (_) {}
        }
      }
    }

    await _save();
  }

  @override
  Future<void> toggleItemCollection(String id, String collectionName) async {
    if (!_initialized) await initialize();
    final int index = _items.indexWhere((item) => item.id == id);
    if (index != -1) {
      final ClipboardItem current = _items[index];
      final Set<String> updatedCollections = Set<String>.from(
        current.collections,
      );
      if (updatedCollections.contains(collectionName)) {
        updatedCollections.remove(collectionName);
      } else {
        updatedCollections.add(collectionName);
      }
      _items[index] = current.copyWith(collections: updatedCollections);
      await _save();
    }
  }

  @override
  Future<void> deleteItem(String id) async {
    if (!_initialized) await initialize();
    final int index = _items.indexWhere((item) => item.id == id);
    if (index != -1) {
      final ClipboardItem item = _items.removeAt(index);
      if (item.imagePath != null) {
        try {
          final File imageFile = File(item.imagePath!);
          if (await imageFile.exists()) {
            await imageFile.delete();
          }
        } catch (_) {}
      }
      await _save();
    }
  }

  @override
  Future<void> clearHistory() async {
    if (!_initialized) await initialize();
    for (final ClipboardItem item in _items) {
      if (item.imagePath != null) {
        try {
          final File imageFile = File(item.imagePath!);
          if (await imageFile.exists()) {
            await imageFile.delete();
          }
        } catch (_) {}
      }
    }
    _items.clear();
    await _save();
  }

  Future<void> _save() async {
    if (_dataFile == null) return;
    try {
      final String encoded = jsonEncode(
        _items.map((item) => item.toJson()).toList(),
      );
      final File tmpFile = File('${_dataFile!.path}.tmp');
      await tmpFile.writeAsString(encoded, flush: true);
      await tmpFile.rename(_dataFile!.path);
    } catch (_) {}
  }
}

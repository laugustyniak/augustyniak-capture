import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/clipboard_item.dart';

class ClipboardRepository {
  ClipboardRepository({this.maxItems = 100});

  final int maxItems;
  List<ClipboardItem> _items = <ClipboardItem>[];
  bool _initialized = false;
  File? _dataFile;

  List<ClipboardItem> get items => List<ClipboardItem>.unmodifiable(_items);

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      final Directory appDir = Directory(p.join(directory.path, 'AugustyniakCapture'));
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
                .map((Map<String, dynamic> json) => ClipboardItem.fromJson(json))
                .toList();
          }
        }
      }
    } catch (_) {
      _items = <ClipboardItem>[];
    }
    _initialized = true;
  }

  Future<List<ClipboardItem>> getItems() async {
    if (!_initialized) await initialize();
    return items;
  }

  Future<void> addItem(ClipboardItem item) async {
    if (!_initialized) await initialize();

    // Avoid duplicate adjacent items with same content
    if (_items.isNotEmpty) {
      final ClipboardItem latest = _items.first;
      if (latest.type == item.type && latest.text == item.text && latest.imagePath == item.imagePath) {
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
      final String encoded = jsonEncode(_items.map((item) => item.toJson()).toList());
      final File tmpFile = File('${_dataFile!.path}.tmp');
      await tmpFile.writeAsString(encoded, flush: true);
      await tmpFile.rename(_dataFile!.path);
    } catch (_) {}
  }
}

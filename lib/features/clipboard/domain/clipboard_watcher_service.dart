import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/clipboard_repository.dart';
import 'clipboard_item.dart';

class ClipboardWatcherService extends ChangeNotifier {
  ClipboardWatcherService({
    required ClipboardRepository repository,
    this.pollInterval = const Duration(milliseconds: 750),
  }) : _repository = repository;

  static const MethodChannel _nativeChannel = MethodChannel('ai.augustyniak.capture/clipboard');

  final ClipboardRepository _repository;
  final Duration pollInterval;
  final Uuid _uuid = const Uuid();

  Timer? _timer;
  String? _lastText;
  String? _lastImagePath;
  bool _isWatching = false;

  bool get isWatching => _isWatching;
  List<ClipboardItem> get items => _repository.items;
  Set<String> get allCollections => _repository.allCollections;

  Future<void> initialize() async {
    await _repository.initialize();
    startWatcher();
  }

  void startWatcher() {
    if (_isWatching) return;
    _isWatching = true;
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _checkClipboard());
  }

  void stopWatcher() {
    _isWatching = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _checkClipboard() async {
    try {
      // 1. Check for native image on clipboard
      final String? imagePath = await _nativeChannel.invokeMethod<String>('getClipboardImage');
      if (imagePath != null && imagePath != _lastImagePath) {
        _lastImagePath = imagePath;
        final ClipboardItem newItem = ClipboardItem(
          id: _uuid.v4(),
          type: ClipboardItemType.image,
          copiedAt: DateTime.now(),
          imagePath: imagePath,
          preview: '[Obrazek]',
        );
        await _repository.addItem(newItem);
        notifyListeners();
        return;
      }

      // 2. Check for text on clipboard
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data == null || data.text == null) return;
      final String text = data.text!;
      if (text.trim().isEmpty) return;

      if (text != _lastText) {
        _lastText = text;
        final ClipboardItem newItem = ClipboardItem(
          id: _uuid.v4(),
          type: ClipboardItemType.text,
          copiedAt: DateTime.now(),
          text: text,
          preview: text.length > 120 ? '${text.substring(0, 120)}...' : text,
        );
        await _repository.addItem(newItem);
        notifyListeners();
      }
    } catch (_) {
      // Platform channels may throw when clipboard access fails
    }
  }

  Future<void> copyToClipboard(ClipboardItem item) async {
    if (item.type == ClipboardItemType.image && item.imagePath != null) {
      _lastImagePath = item.imagePath;
      try {
        await _nativeChannel.invokeMethod('copyImageToClipboard', {'path': item.imagePath});
      } catch (_) {}
      notifyListeners();
    } else if (item.text != null) {
      _lastText = item.text;
      await Clipboard.setData(ClipboardData(text: item.text!));
      notifyListeners();
    }
  }

  Future<void> toggleItemCollection(String id, String collectionName) async {
    await _repository.toggleItemCollection(id, collectionName);
    notifyListeners();
  }

  Future<void> deleteItem(String id) async {
    await _repository.deleteItem(id);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await _repository.clearHistory();
    _lastText = null;
    _lastImagePath = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stopWatcher();
    super.dispose();
  }
}

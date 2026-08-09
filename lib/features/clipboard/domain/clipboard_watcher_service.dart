import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/clipboard_repository.dart';
import 'clipboard_item.dart';

abstract interface class ClipboardGateway {
  Future<String?> getImagePath();
  Future<void> copyImage(String path);
  Future<String?> getText();
  Future<void> copyText(String text);
}

class SystemClipboardGateway implements ClipboardGateway {
  static const MethodChannel _nativeChannel = MethodChannel(
    'ai.augustyniak.capture/clipboard',
  );

  @override
  Future<String?> getImagePath() =>
      _nativeChannel.invokeMethod<String>('getClipboardImage');

  @override
  Future<void> copyImage(String path) async {
    await _nativeChannel.invokeMethod<void>(
      'copyImageToClipboard',
      <String, Object>{'path': path},
    );
  }

  @override
  Future<String?> getText() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

class ClipboardWatcherService extends ChangeNotifier {
  ClipboardWatcherService({
    required ClipboardRepository repository,
    this.pollInterval = const Duration(milliseconds: 750),
    ClipboardGateway? gateway,
  }) : _repository = repository,
       _gateway = gateway ?? SystemClipboardGateway();

  final ClipboardRepository _repository;
  final ClipboardGateway _gateway;
  final Duration pollInterval;
  final Uuid _uuid = const Uuid();

  Timer? _timer;
  String? _lastText;
  String? _lastImagePath;
  bool _isWatching = false;
  bool _checkInFlight = false;

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
    _timer = Timer.periodic(pollInterval, (_) => unawaited(checkNow()));
  }

  void stopWatcher() {
    _isWatching = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> checkNow() async {
    if (_checkInFlight) return;
    _checkInFlight = true;
    try {
      // 1. Check for native image on clipboard
      String? imagePath;
      try {
        imagePath = await _gateway.getImagePath();
      } catch (_) {
        // Image clipboard support is optional; text must still be observed on
        // platforms that do not implement the native image channel.
      }
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
      final String? clipboardText = await _gateway.getText();
      if (clipboardText == null) return;
      final String text = clipboardText;
      if (text.trim().isEmpty) return;

      if (text != _lastText) {
        _lastText = text;
        final ClipboardItem newItem = ClipboardItem(
          id: _uuid.v4(),
          type: ClipboardItemType.text,
          copiedAt: DateTime.now(),
          text: text,
          preview: ClipboardItem.previewFor(text),
        );
        await _repository.addItem(newItem);
        notifyListeners();
      }
    } catch (_) {
      // Platform channels may throw when clipboard access fails
    } finally {
      _checkInFlight = false;
    }
  }

  Future<void> copyToClipboard(ClipboardItem item) async {
    if (item.type == ClipboardItemType.image && item.imagePath != null) {
      _lastImagePath = item.imagePath;
      try {
        await _gateway.copyImage(item.imagePath!);
      } catch (_) {}
      notifyListeners();
    } else if (item.text != null) {
      _lastText = item.text;
      await _gateway.copyText(item.text!);
      notifyListeners();
    }
  }

  /// Ask the platform to type ⌘V into whatever had focus before the sheet
  /// opened. Implemented on macOS only; everywhere else the channel has no
  /// handler and the entry is merely left on the clipboard.
  ///
  /// **The `await` is what makes the `catch` reachable.** Without it the call
  /// returns a future nobody holds, so `MissingPluginException` — the ordinary
  /// answer on Android, iOS and Linux — escaped as an unhandled async error
  /// instead of being swallowed here as intended.
  Future<void> pasteToActiveApp() async {
    try {
      await const MethodChannel(
        'ai.augustyniak.capture/clipboard',
      ).invokeMethod<void>('autoPaste');
    } catch (_) {}
  }

  Future<void> toggleItemCollection(String id, String collectionName) async {
    await _repository.toggleItemCollection(id, collectionName);
    notifyListeners();
  }

  /// Overwrites an entry's text in place.
  ///
  /// Deliberately leaves `_lastText` and `_lastImagePath` alone: an edit never
  /// writes to the system clipboard, so the next poll sees nothing new and no
  /// duplicate of our own edit is captured.
  Future<void> updateItemText(String id, String text) async {
    await _repository.updateItemText(id, text);
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

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/clipboard_repository.dart';
import 'auto_paste.dart';
import 'clipboard_item.dart';

abstract interface class ClipboardGateway {
  Future<String?> getImagePath();
  Future<void> copyImage(String path);
  Future<String?> getText();

  /// Whether the source marked the current clipboard content as sensitive —
  /// a password manager's copy, a one-time code. Read through the native
  /// channel (`isClipboardSensitive`); a platform without the method, or
  /// one whose clipboard cannot be read right now, answers false.
  Future<bool> isSensitive();

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
  Future<bool> isSensitive() async {
    try {
      return await _nativeChannel.invokeMethod<bool>('isClipboardSensitive') ??
          false;
    } catch (_) {
      // No native handler on this platform (Linux without the hint, iOS),
      // or a channel error: the content is observed as before.
      return false;
    }
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
    AutoPaste autoPaste = const ChannelAutoPaste(),

    /// Entries older than this are pruned on the next poll (#302). Null keeps
    /// everything; the default is 30 days. Read on every prune, so a Config
    /// change applies without a restart.
    Duration? Function() retention = _defaultRetention,
    DateTime Function() clock = DateTime.now,
  }) : _repository = repository,
       _gateway = gateway ?? SystemClipboardGateway(),
       _autoPaste = autoPaste,
       _retention = retention,
       _clock = clock;

  static Duration? _defaultRetention() => const Duration(days: 30);

  /// Shortest gap between two prunes.
  static const Duration pruneEvery = Duration(minutes: 1);

  final ClipboardRepository _repository;
  final ClipboardGateway _gateway;
  final AutoPaste _autoPaste;
  final Duration? Function() _retention;
  final DateTime Function() _clock;
  final Duration pollInterval;
  final Uuid _uuid = const Uuid();

  Timer? _timer;
  DateTime? _lastPrune;
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
      await _pruneExpired();

      // A source that marked its content sensitive (#302) gets nothing
      // recorded — not the image, not the text. `_lastText`/`_lastImagePath`
      // stay as they were, so when the clipboard returns to the previous
      // content nothing is re-indexed either.
      if (await _gateway.isSensitive()) return;

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
          preview: '[Image]',
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

  /// Once a minute at most: a DELETE every 750 ms would be pure churn, and
  /// a window measured in days does not need better than that.
  Future<void> _pruneExpired() async {
    final Duration? window = _retention();
    if (window == null) return;
    final DateTime now = _clock();
    if (_lastPrune != null && now.difference(_lastPrune!) < pruneEvery) return;
    _lastPrune = now;
    try {
      if (await _repository.pruneOlderThan(now.subtract(window)) > 0) {
        notifyListeners();
      }
    } catch (_) {
      // A failed prune costs disk, never the poll that reads the clipboard.
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

  /// Write down the window that currently has focus, so [pasteToActiveApp] can
  /// give it back.
  ///
  /// **Call this before anything raises the app's own window**, including the
  /// compact overlay the hotkey opens — X11 keeps no focus history, so asked
  /// afterwards the platform answers with our own window. Errors are swallowed
  /// on the same rule as the paste itself: failing to record a target costs the
  /// convenience, never the entry.
  Future<void> rememberPasteTarget() async {
    try {
      await _autoPaste.rememberTarget();
    } catch (_) {}
  }

  /// Ask the platform to type the paste keystroke into whatever had focus
  /// before the sheet opened — ⌘V through the channel on macOS, Ctrl+V through
  /// `xdotool` on Linux. Where neither is available the entry is merely left on
  /// the clipboard.
  ///
  /// **The `await` is what makes the `catch` reachable.** Without it the call
  /// returns a future nobody holds, so `MissingPluginException` — the ordinary
  /// answer on Android and iOS — escaped as an unhandled async error instead of
  /// being swallowed here as intended.
  Future<void> pasteToActiveApp() async {
    try {
      await _autoPaste.pasteToTarget();
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

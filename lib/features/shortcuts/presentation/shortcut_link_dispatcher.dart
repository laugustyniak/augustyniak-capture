import 'dart:async';

import '../../logs/domain/log_event.dart';
import '../domain/shortcut_action.dart';
import '../domain/shortcut_link.dart';
import '../domain/shortcut_link_source.dart';

/// Maps a shortcut URL (`ai.augustyniak.capture://shortcut/<action>`) onto the
/// same `ShortcutsCoordinator.handle` a hotkey press reaches, so a desktop that
/// owns the key itself (GNOME Wayland) pulls exactly the same lever.
///
/// Holds no action logic. Links that arrive before [markReady] — and the
/// cold-start URL in [launchArguments] — are held until the shell has loaded,
/// because an action run against an unloaded controller would act on an empty
/// queue. A URL that is not a shortcut is ignored silently: the OAuth callback
/// shares the scheme and belongs to Supabase. A shortcut URL naming an unknown
/// action does nothing and is logged.
class ShortcutLinkDispatcher {
  ShortcutLinkDispatcher({
    required ShortcutLinkSource source,
    required Future<void> Function(ShortcutAction action) handle,
    Iterable<String> launchArguments = const <String>[],
    LogSink logSink = const NoopLogSink(),
  }) : _source = source,
       _handle = handle,
       _launchArguments = List<String>.unmodifiable(launchArguments),
       _logSink = logSink;

  final ShortcutLinkSource _source;
  final Future<void> Function(ShortcutAction action) _handle;
  final List<String> _launchArguments;
  final LogSink _logSink;

  final List<ShortcutAction> _pending = <ShortcutAction>[];
  StreamSubscription<Uri>? _subscription;
  bool _ready = false;
  bool _disposed = false;

  /// Subscribes to the link source and queues the cold-start URL. Idempotent.
  void start() {
    if (_subscription != null || _disposed) return;
    for (final String argument in _launchArguments) {
      final Uri? uri = Uri.tryParse(argument);
      if (uri != null) _accept(uri);
    }
    _subscription = _source.links.listen(
      _accept,
      onError: (Object error) => _logSink.log(
        'Shortcut link stream failed: $error',
        level: LogLevel.warn,
      ),
    );
  }

  /// Runs every action held so far, in arrival order, and dispatches later ones
  /// as they come. The held actions run once; a second call finds none.
  Future<void> markReady() async {
    if (_disposed) return;
    _ready = true;
    final List<ShortcutAction> held = List<ShortcutAction>.of(_pending);
    _pending.clear();
    for (final ShortcutAction action in held) {
      await _run(action);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pending.clear();
    await _subscription?.cancel();
    _subscription = null;
  }

  void _accept(Uri uri) {
    if (_disposed || !ShortcutLink.isShortcut(uri)) return;
    final ShortcutAction? action = ShortcutLink.actionOf(uri);
    if (action == null) {
      _logSink.log(
        'Ignored shortcut URL with an unknown action: $uri',
        level: LogLevel.warn,
      );
      return;
    }
    if (!_ready) {
      _pending.add(action);
      return;
    }
    // Not awaited, exactly like a hotkey press: a sheet action resolves only
    // when its sheet closes, and a second URL must not queue behind it.
    unawaited(_run(action));
  }

  Future<void> _run(ShortcutAction action) async {
    if (_disposed) return;
    try {
      await _handle(action);
    } catch (error) {
      _logSink.log(
        'Shortcut URL ${action.name} failed: $error',
        level: LogLevel.error,
      );
    }
  }
}

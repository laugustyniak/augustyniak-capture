import 'shortcut_action.dart';

/// The URL a desktop environment opens to trigger a shortcut action:
/// `ai.augustyniak.capture://shortcut/<ShortcutAction.name>`.
///
/// It exists for GNOME Wayland, where no application may grab a key
/// system-wide and `keybinder` fails every registration. There the desktop
/// owns the key (`tool/gnome-shortcuts.sh`) and runs `xdg-open` on this URL;
/// the second process forwards it to the running instance, which pulls the
/// same `ShortcutsCoordinator.handle` lever a hotkey would.
abstract final class ShortcutLink {
  /// The registered URL scheme — the application identifier, the same one the
  /// OAuth callback rides on.
  static const String scheme = 'ai.augustyniak.capture';
  static const String host = 'shortcut';

  static Uri forAction(ShortcutAction action) =>
      Uri(scheme: scheme, host: host, path: '/${action.name}');

  /// Whether [uri] is addressed to the shortcut layer at all, whatever action
  /// it names. Anything else — the OAuth callback included — belongs to
  /// someone else and must be left alone.
  static bool isShortcut(Uri uri) => uri.scheme == scheme && uri.host == host;

  /// The action [uri] names, or null when it is not a shortcut URL or names an
  /// action this build does not have.
  static ShortcutAction? actionOf(Uri uri) {
    if (!isShortcut(uri)) return null;
    final List<String> segments = uri.pathSegments
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.length != 1) return null;
    return ShortcutAction.fromName(segments.single);
  }
}

/// Which palette the app paints in.
///
/// Deliberately *not* Flutter's `ThemeMode`: this layer stays pure Dart so the
/// settings round-trip tests need no binding, and the mapping to Material lives
/// in `app.dart` next to the `MaterialApp` that consumes it — the same split
/// `HotkeyBinding` draws between the stored key identity and the widget that
/// registers it.
enum AppThemeMode {
  /// Follow the operating system. The default, and the one value that cannot
  /// age: it delegates rather than deciding, so unlike the enrichment profile
  /// or the shortcut map there is no better default a later build could ship.
  /// That is why this field is a plain enum with a default rather than the
  /// three-state private-nullable dance those two use.
  system,
  dark,
  light;

  /// Unknown and absent both answer [system], the same way
  /// `CaptureType.fromName` defaults rather than dropping the row: a
  /// `settings.json` written by a newer build that grew a fourth mode must
  /// still open, and following the OS is the safe thing to do while it does.
  static AppThemeMode fromName(String? name) => switch (name) {
    'dark' => AppThemeMode.dark,
    'light' => AppThemeMode.light,
    _ => AppThemeMode.system,
  };

  String get label => switch (this) {
    AppThemeMode.system => 'SYSTEM',
    AppThemeMode.dark => 'DARK',
    AppThemeMode.light => 'LIGHT',
  };
}

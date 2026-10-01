/// How tall a row in the Queue's master list is.
///
/// Pure Dart for the reason [AppThemeMode] is: the settings round-trip tests
/// need no binding, and the padding it maps to lives with the row that draws
/// it.
enum QueueDensity {
  /// One summary line and tight padding — what lets a 1440 px window show a
  /// day's worth of captures without scrolling. The default.
  compact,

  /// A second summary line and more air around it.
  comfortable;

  /// Unknown and absent both answer [compact], so a `settings.json` written
  /// by a newer build that grew a third density still opens.
  static QueueDensity fromName(String? name) => switch (name) {
    'comfortable' => QueueDensity.comfortable,
    _ => QueueDensity.compact,
  };

  String get label => switch (this) {
    QueueDensity.compact => 'Compact',
    QueueDensity.comfortable => 'Comfortable',
  };
}

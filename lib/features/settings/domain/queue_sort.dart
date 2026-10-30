/// The Queue's list order.
///
/// Pure Dart for the reason [QueueDensity] is: it is persisted in
/// `AppSettings`, whose round-trip tests need no binding.
enum QueueSort {
  /// The controller's order.
  newest,

  /// Focus order, P0 to P3 then unranked, oldest first within a rank. The
  /// default.
  priority;

  /// Unknown and absent both answer [priority], so a file that never stored a
  /// choice opens in focus order.
  static QueueSort fromName(String? name) => switch (name) {
    'newest' => QueueSort.newest,
    _ => QueueSort.priority,
  };
}

/// How much a capture matters, judged against the user's own goals — the
/// enrichment profile ("soul") — and correctable by the user.
///
/// Declared most urgent first, so `index` sorts a queue the way it is read.
///
/// **There is no "unranked" value: unranked is null.** Null means nobody has
/// judged the item — enrichment never ran, or the model gave no usable answer.
/// [p3] means it was judged and is not important. Folding the two together
/// would make an unconfigured install look like one where everything is low.
enum CapturePriority {
  /// Do now: a deadline, a client waiting, a blocker.
  p0,

  /// This week: moves a current goal forward.
  p1,

  /// Some day: useful, no pressure.
  p2,

  /// Low: off-goal, or matches an anti-goal.
  p3;

  /// Unlike `CaptureCategory.fromName`, an unknown name degrades to **null**,
  /// not to a default: there is no neutral rank to land on, and inventing one
  /// would claim a judgement nobody made. Case-insensitive, because models
  /// write "P1" as often as "p1".
  static CapturePriority? tryName(Object? name) {
    if (name is! String) return null;
    return CapturePriority.values.asNameMap()[name.trim().toLowerCase()];
  }

  /// The card chip and the editor label.
  String get label => name.toUpperCase();
}

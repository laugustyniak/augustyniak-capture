/// Tag normalisation and loading, for a plain `List<String>`.
///
/// Tags carry **no provenance**. A capture has one list of tags; enrichment may
/// propose it and the user may rewrite it, and once written down the two are
/// indistinguishable — which is the point. An earlier model stored an owner per
/// tag (`ai` / `human`) so each side could update only its own layer, but that
/// made the *editor* the thing the user had to understand: a model tag could
/// not be deleted, only "promoted", and the same word rendered in two colours
/// depending on who typed it first. A tag list is a tag list.
///
/// What survives from that model is [fromJson], which still reads the object
/// form — rows written while provenance existed are already on disk, and the
/// owner is simply dropped when they load.
class RecordingTags {
  const RecordingTags._();

  /// Lowercase and trimmed. Tags are matched, searched and de-duped by value,
  /// so `Acme` and `acme` have to be one tag rather than two that look alike.
  static String normalizeValue(String value) => value.trim().toLowerCase();

  /// Normalises, drops blanks and de-dupes, **keeping first-seen order** —
  /// order is the user's, so a re-save must not shuffle their list.
  static List<String> normalize(Iterable<String> tags) {
    final Set<String> seen = <String>{};
    final List<String> normalized = <String>[];
    for (final String tag in tags) {
      final String value = normalizeValue(tag);
      if (value.isEmpty || !seen.add(value)) continue;
      normalized.add(value);
    }
    return List<String>.unmodifiable(normalized);
  }

  /// Reads the `tags` field of a persisted row.
  ///
  /// Three shapes are accepted, because all three exist on disk: a plain string
  /// list (the original format and the current one), an object list carrying
  /// the retired `{value, source}` pair, and anything else — which yields no
  /// tags rather than throwing, so one hand-edited row cannot take the whole
  /// index down with it.
  static List<String> fromJson(dynamic json) {
    if (json is! List<dynamic>) return const <String>[];
    return normalize(json.map(_valueOf).whereType<String>());
  }

  static String? _valueOf(dynamic entry) {
    if (entry is String) return entry;
    // The provenance-era shape. `source` is read and discarded: which side
    // wrote a tag is no longer something the app models.
    if (entry is Map<String, dynamic> && entry['value'] is String) {
      return entry['value'] as String;
    }
    return null;
  }
}

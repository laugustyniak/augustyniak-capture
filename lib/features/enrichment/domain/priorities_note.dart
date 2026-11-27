/// The user's current priorities, parsed out of a markdown note.
///
/// Pure and total: [parse] never throws, and anything it cannot read becomes
/// an empty list rather than an error. `tier` and `status` are note-level
/// (frontmatter), not per item.
class PrioritiesNote {
  const PrioritiesNote({this.items = const <String>[], this.tier, this.status});

  static const int maxItems = 20;
  static const int maxItemChars = 120;

  /// Top-level list items in document order, or the level-2+ headings when the
  /// note has no list. Empty means the note was read and nothing parsed.
  final List<String> items;
  final int? tier;
  final String? status;

  static final RegExp _listItem = RegExp(r'^(?:[-*+]|\d+[.)])[ \t]+(.*)$');
  static final RegExp _checkbox = RegExp(r'^\[[ xX]\][ \t]+');
  static final RegExp _heading = RegExp(r'^#{2,}[ \t]+(.*)$');
  static final RegExp _wikilink = RegExp(r'\[\[(?:[^\]|]*\|)?([^\]]*)\]\]');

  factory PrioritiesNote.parse(String text) {
    try {
      return _parse(text);
    } catch (_) {
      return const PrioritiesNote();
    }
  }

  static PrioritiesNote _parse(String text) {
    final List<String> lines = text.split(RegExp(r'\r?\n'));
    int? tier;
    String? status;
    int start = 0;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final int end = lines.indexWhere((String l) => l.trim() == '---', 1);
      if (end > 0) {
        for (final String line in lines.sublist(1, end)) {
          final int colon = line.indexOf(':');
          if (colon <= 0 || line.startsWith(RegExp(r'\s'))) continue;
          final String key = line.substring(0, colon).trim();
          // A trailing ` # comment` and one pair of surrounding quotes are
          // YAML spelling, not part of the value.
          String value = line
              .substring(colon + 1)
              .replaceFirst(RegExp(r'\s+#.*$'), '')
              .trim();
          if (value.length >= 2 &&
              (value[0] == '"' || value[0] == "'") &&
              value[value.length - 1] == value[0]) {
            value = value.substring(1, value.length - 1).trim();
          }
          if (value.isEmpty || RegExp(r'[:\[\]{}]').hasMatch(value)) continue;
          if (key == 'tier') tier = int.tryParse(value);
          if (key == 'status') status = value;
        }
        start = end + 1;
      }
    }

    final List<String> listed = <String>[];
    final List<String> headings = <String>[];
    for (final String line in lines.sublist(start)) {
      final RegExpMatch? item = _listItem.firstMatch(line);
      if (item != null) {
        final String cleaned = _clean(
          item.group(1)!.replaceFirst(_checkbox, ''),
        );
        if (cleaned.isNotEmpty) listed.add(cleaned);
        continue;
      }
      final RegExpMatch? heading = _heading.firstMatch(line);
      if (heading != null) {
        final String cleaned = _clean(heading.group(1)!);
        if (cleaned.isNotEmpty) headings.add(cleaned);
      }
    }
    final List<String> chosen = listed.isNotEmpty ? listed : headings;
    return PrioritiesNote(
      items: chosen.take(maxItems).toList(growable: false),
      tier: tier,
      status: status,
    );
  }

  static String _clean(String raw) {
    final String flat = raw
        .replaceAllMapped(_wikilink, (Match m) => m.group(1)!)
        .trim();
    return flat.length <= maxItemChars ? flat : flat.substring(0, maxItemChars);
  }
}

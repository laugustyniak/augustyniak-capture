/// Whether the user is still on the hook for a [Commitment].
///
/// `open` is the model's default. `done` and `dismissed` are the user's own
/// answers, and enrichment never moves a commitment out of either — see
/// [mergeCommitments].
enum CommitmentState {
  open,
  done,
  dismissed;

  /// Unknown names from a newer build read as [open]: showing a commitment the
  /// user may already have handled is cheaper than hiding one they have not.
  static CommitmentState fromName(Object? name) {
    for (final CommitmentState state in values) {
      if (state.name == name) return state;
    }
    return open;
  }
}

/// A promise found in a capture ("I'll send the offer by Friday"), with an
/// optional due date and an optional person it involves.
class Commitment {
  const Commitment({
    required this.text,
    this.due,
    this.who,
    this.state = CommitmentState.open,
  });

  static const int maxTextChars = 200;
  static const int maxWhoChars = 80;

  /// What was promised, in the capture's own words.
  final String text;

  /// A calendar date (midnight, local), already resolved against the capture's
  /// `createdAt`. Null when the capture named no date the resolver could read.
  final DateTime? due;

  /// Who it involves, as the model named them. Null when nobody was named.
  final String? who;

  final CommitmentState state;

  bool get isOpen => state == CommitmentState.open;

  /// Identity across enrichment runs: the text, case- and space-folded. The
  /// model rephrasing a line is a new commitment; re-capitalising it is not.
  String get key => keyFor(text);

  static String keyFor(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Commitment copyWith({CommitmentState? state}) =>
      Commitment(text: text, due: due, who: who, state: state ?? this.state);

  /// `due`, `who` and an `open` state are omitted while absent, so the row
  /// stays as small as the information in it.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    if (due != null) 'due': formatDate(due!),
    if (who != null) 'who': who,
    if (state != CommitmentState.open) 'state': state.name,
  };

  /// Null for anything that is not an object with a non-blank `text`; an
  /// unreadable `due` or `who` costs that field, not the commitment.
  static Commitment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final Object? who = raw['who'];
    return Commitment(
      text: text.trim(),
      due: raw['due'] is String ? parseDate(raw['due'] as String) : null,
      who: who is String && who.trim().isNotEmpty ? who.trim() : null,
      state: CommitmentState.fromName(raw['state']),
    );
  }

  /// Null when [raw] is not a list — "never extracted". A list keeps its
  /// readable entries, and stays a (possibly empty) list: something was
  /// extracted, even if nothing of it survived.
  static List<Commitment>? listFromJson(Object? raw) {
    if (raw is! List) return null;
    return <Commitment>[
      for (final Object? entry in raw)
        if (fromJson(entry) case final Commitment commitment) commitment,
    ];
  }

  static String formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

  /// The calendar date at the head of an ISO string, or null when it is not a
  /// real date (`2026-13-40` does not roll over into next year).
  static DateTime? parseDate(String raw) {
    final RegExpMatch? match = _isoDate.firstMatch(raw.trim());
    if (match == null) return null;
    final int year = int.parse(match.group(1)!);
    final int month = int.parse(match.group(2)!);
    final int day = int.parse(match.group(3)!);
    final DateTime date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }
}

/// A commitment as the enrichment model reported it, before its due phrase is
/// resolved against the capture.
class CommitmentDraft {
  const CommitmentDraft({required this.text, this.due, this.who});

  final String text;

  /// The deadline as the model gave it: an ISO date or an English phrase
  /// ("friday", "next week"). Never resolved by the model itself — it does not
  /// know when the capture was made, only when it is being asked.
  final String? due;
  final String? who;
}

/// The model's latest extraction applied over what the item already holds.
///
/// Null [extracted] means the reply said nothing about commitments, and the
/// result is null too: leave the stored list alone. Otherwise the fresh list
/// wins for everything the model owns, with two rules for what the user owns:
///
/// - a re-extracted commitment keeps the state the user gave it;
/// - a commitment the user marked done or dismissed survives even when the
///   model no longer reports it, because that decision was theirs. An `open`
///   one the model dropped is the model's to drop.
List<Commitment>? mergeCommitments({
  required List<Commitment>? existing,
  required List<CommitmentDraft>? extracted,
  required DateTime anchor,
}) {
  if (extracted == null) return null;
  final Map<String, Commitment> previous = <String, Commitment>{
    for (final Commitment c in existing ?? const <Commitment>[]) c.key: c,
  };
  final Set<String> seen = <String>{};
  final List<Commitment> merged = <Commitment>[];
  for (final CommitmentDraft draft in extracted) {
    final String text = draft.text.trim();
    if (text.isEmpty) continue;
    final String key = Commitment.keyFor(text);
    if (!seen.add(key)) continue;
    merged.add(
      Commitment(
        text: text,
        due: resolveCommitmentDue(draft.due, anchor),
        who: draft.who,
        state: previous[key]?.state ?? CommitmentState.open,
      ),
    );
  }
  for (final Commitment kept in existing ?? const <Commitment>[]) {
    if (!kept.isOpen && seen.add(kept.key)) merged.add(kept);
  }
  return merged;
}

const List<String> _weekdays = <String>[
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

const Map<String, int> _numbers = <String, int>{
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
};

/// Turns the model's due phrase into a calendar date, relative to [anchor] —
/// the capture's `createdAt`, never the time enrichment happens to run. "By
/// Friday" said on a Wednesday means that Friday even when the item is
/// re-enriched a month later.
///
/// Reads an ISO date, `today`/`tonight`, `tomorrow`, `day after tomorrow`,
/// `in N days|weeks|months`, weekday names (bare or with `this`/`next`),
/// `next week`, `end of (the) week`, `next month` and `end of (the) month`.
/// A bare weekday means the next one strictly after the anchor day; `this` on
/// the same weekday means the anchor day itself; `next` means that weekday in
/// the following week. Anything else is null — no date beats a guessed one.
DateTime? resolveCommitmentDue(String? phrase, DateTime anchor) {
  if (phrase == null) return null;
  final DateTime? iso = Commitment.parseDate(phrase);
  if (iso != null) return iso;

  String text = phrase.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  text = text.replaceFirst(RegExp(r'^(by|on|until|before|due) '), '');
  text = text.replaceAll(RegExp(r'[.!]$'), '');
  if (text.isEmpty) return null;

  final DateTime day = DateTime(anchor.year, anchor.month, anchor.day);
  DateTime plus(int days) => DateTime(day.year, day.month, day.day + days);
  // Monday = 1 … Sunday = 7, as `DateTime.weekday`.
  final int weekday = day.weekday;

  switch (text) {
    case 'today' || 'tonight' || 'this evening' || 'end of day' || 'eod':
      return day;
    case 'tomorrow':
      return plus(1);
    case 'day after tomorrow' || 'the day after tomorrow':
      return plus(2);
    case 'next week':
      return plus(8 - weekday);
    case 'end of week' || 'end of the week' || 'this week':
      return plus((5 - weekday) % 7);
    case 'next month':
      return DateTime(day.year, day.month + 1, 1);
    case 'end of month' || 'end of the month' || 'this month':
      return DateTime(day.year, day.month + 1, 0);
  }

  final RegExpMatch? span = RegExp(
    r'^in (\d+|[a-z]+) (day|days|week|weeks|month|months)$',
  ).firstMatch(text);
  if (span != null) {
    final String count = span.group(1)!;
    final int? n = int.tryParse(count) ?? _numbers[count];
    if (n == null) return null;
    final String unit = span.group(2)!;
    if (unit.startsWith('day')) return plus(n);
    if (unit.startsWith('week')) return plus(n * 7);
    return DateTime(day.year, day.month + n, day.day);
  }

  final RegExpMatch? named = RegExp(
    r'^(this |next )?([a-z]+)$',
  ).firstMatch(text);
  if (named != null) {
    final int index = _weekdays.indexOf(named.group(2)!);
    if (index < 0) return null;
    final int target = index + 1;
    final String? qualifier = named.group(1)?.trim();
    if (qualifier == 'next') {
      // Monday of next week, then forward to the target day.
      return plus(8 - weekday + target - 1);
    }
    final int ahead = (target - weekday) % 7;
    if (ahead == 0) return qualifier == 'this' ? day : plus(7);
    return plus(ahead);
  }
  return null;
}

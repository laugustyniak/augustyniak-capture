/// Who changed a field.
///
/// The distinction is the whole reason this record exists: the app rewrites a
/// capture's title, category, summary and tags from a model's answer, and the
/// user needs to be able to tell "I named this" from "a model named this" — and
/// to see what the previous answer was when a re-run replaces it.
enum RevisionSource {
  /// A hand edit: the edit sheet, or the category dropdown.
  user,

  /// The enrichment stage — an LLM call that produced a title, category,
  /// summary and tags from the item's text.
  enrichment,

  /// The processor that produced the item's text in the first place
  /// (transcription, OCR, or the note passthrough).
  processor;

  /// Unknown names degrade to [processor] rather than throwing, the same
  /// forward-compatibility rule `CaptureType.fromName` follows: a history file
  /// written by a newer build must still load in an older one.
  static RevisionSource fromName(String? name) =>
      RevisionSource.values.asNameMap()[name] ?? RevisionSource.processor;

  String get label => switch (this) {
    RevisionSource.user => 'YOU',
    RevisionSource.enrichment => 'MODEL',
    RevisionSource.processor => 'PIPELINE',
  };
}

/// One field of one capture changing value, once.
///
/// Deliberately field-level rather than snapshot-level. A snapshot per change
/// would duplicate an entire transcript every time a tag moved, and the
/// question this answers is always about a single field: *what was the title
/// before the model rewrote it, and what did the transcript say before the
/// re-run replaced it.*
class RecordingRevision {
  const RecordingRevision({
    required this.recordingId,
    required this.at,
    required this.field,
    required this.from,
    required this.to,
    required this.source,
  });

  /// The capture this belongs to. Present in every row because the history is
  /// one flat append-only file, not one file per item.
  final String recordingId;
  final DateTime at;

  /// The `Recording` field name as written in its JSON: `title`, `category`,
  /// `summary`, `tags` or `transcript`.
  final String field;

  /// Previous and new values, rendered as text. Null means the field was unset
  /// — which is a real, distinct state: `from == null` is "the model filled a
  /// blank", `to == null` is "the user cleared it".
  ///
  /// Rendered rather than typed because the five tracked fields have three
  /// different Dart types and the history only ever displays them; keeping the
  /// row a flat string pair is also what lets an older build read a newer
  /// build's file.
  final String? from;
  final String? to;

  final RevisionSource source;

  /// Longest value kept per side. A 90-minute transcript is ~100 kB, and a
  /// history that stored two full copies of it per re-run would outgrow every
  /// recording in the app. Truncation is marked in the text so the UI never
  /// presents a clipped value as if it were whole.
  static const int maxValueLength = 20000;

  static String? truncate(String? value) {
    if (value == null) return null;
    if (value.length <= maxValueLength) return value;
    return '${value.substring(0, maxValueLength)}\n… '
        '[${value.length - maxValueLength} more characters not kept in history]';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recordingId': recordingId,
    'at': at.toIso8601String(),
    'field': field,
    'from': from,
    'to': to,
    'source': source.name,
  };

  /// Throws on a row missing its required keys; the repository skips such rows
  /// rather than failing the whole load, exactly as the recordings index does.
  factory RecordingRevision.fromJson(Map<String, dynamic> json) {
    return RecordingRevision(
      recordingId: json['recordingId'] as String,
      at: DateTime.parse(json['at'] as String),
      field: json['field'] as String,
      from: json['from'] is String ? json['from'] as String : null,
      to: json['to'] is String ? json['to'] as String : null,
      source: RevisionSource.fromName(json['source'] as String?),
    );
  }
}

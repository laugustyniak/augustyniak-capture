import 'capture_type.dart';

/// One source artifact belonging to a capture.
///
/// A capture starts with exactly one segment and gains further ones when the
/// user appends a fragment. The segment — not the capture — is the unit of
/// processing and of retry: it carries its own [CaptureType], so a photo
/// appended to an audio note reaches `OcrProcessor`, and its own [text] and
/// [error], so a fragment that fails cannot cost the fragments that worked.
///
/// **Pending is defined by [text] alone.** No per-segment status enum exists:
/// `RecordingStatus` already answers queued/running/failed for the capture, and
/// a second persisted enum would be a second thing to keep in agreement.
class CaptureSegment {
  const CaptureSegment({
    required this.index,
    required this.filePath,
    required this.type,
    required this.createdAt,
    this.sourceMimeType,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.contentHash,
    this.text,
    this.error,
  });

  /// Position in the capture, and the suffix of the file name for anything
  /// past the first: segment 0 is `<id>.<ext>`, segment n is `<id>-<n>.<ext>`.
  final int index;
  final String filePath;
  final CaptureType type;
  final String? sourceMimeType;
  final DateTime createdAt;
  final int durationMs;
  final int sizeBytes;

  /// SHA-256 of this segment's bytes, or null until the backfill computes it.
  final String? contentHash;

  /// Processor output for this segment. Null means it has not been processed.
  final String? text;

  /// Why the last attempt at this segment failed. Independent of the capture's
  /// `error`, which reports whichever segment failed most recently.
  final String? error;

  bool get isPending => text == null;

  CaptureSegment copyWith({
    String? text,
    bool clearText = false,
    String? error,
    bool clearError = false,
    String? contentHash,
    int? durationMs,
    int? sizeBytes,
  }) {
    return CaptureSegment(
      index: index,
      filePath: filePath,
      type: type,
      sourceMimeType: sourceMimeType,
      createdAt: createdAt,
      durationMs: durationMs ?? this.durationMs,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      contentHash: contentHash ?? this.contentHash,
      text: clearText ? null : (text ?? this.text),
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'filePath': filePath,
    'type': type.name,
    'sourceMimeType': sourceMimeType,
    'createdAt': createdAt.toIso8601String(),
    'durationMs': durationMs,
    'sizeBytes': sizeBytes,
    'contentHash': contentHash,
    'text': text,
    'error': error,
  };

  factory CaptureSegment.fromJson(Map<String, dynamic> json) {
    return CaptureSegment(
      index: json['index'] as int,
      filePath: json['filePath'] as String,
      // Degrades rather than throwing, the same rule `Recording.type` follows.
      type: CaptureType.fromName(json['type'] as String?),
      sourceMimeType: json['sourceMimeType'] is String
          ? json['sourceMimeType'] as String
          : null,
      createdAt: DateTime.parse(json['createdAt'] as String),
      durationMs: json['durationMs'] as int? ?? 0,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      contentHash: json['contentHash'] is String
          ? json['contentHash'] as String
          : null,
      text: json['text'] is String ? json['text'] as String : null,
      error: json['error'] is String ? json['error'] as String : null,
    );
  }

  /// Unreadable entries are dropped one at a time rather than throwing out of
  /// the whole load — the same rule `tags` and `routes` follow.
  static List<CaptureSegment> listFromJson(dynamic raw) {
    if (raw is! List) return const <CaptureSegment>[];
    final List<CaptureSegment> parsed = <CaptureSegment>[];
    for (final dynamic entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        parsed.add(CaptureSegment.fromJson(entry));
      } catch (_) {
        // One unreadable segment must not cost the capture.
      }
    }
    return parsed;
  }
}

/// How a segment's output joins the capture's text.
///
/// Accumulation, never a recompute of the whole join: `editTranscript` exists
/// and people correct transcripts, so rebuilding the text from the segments
/// after an append would silently undo a hand edit.
String appendSegmentText(String? existing, String addition) {
  final String trimmed = addition.trim();
  if (existing == null || existing.trim().isEmpty) return trimmed;
  if (trimmed.isEmpty) return existing;
  return '$existing\n\n$trimmed';
}

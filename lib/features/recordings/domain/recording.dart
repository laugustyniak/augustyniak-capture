import 'capture_category.dart';
import 'capture_type.dart';

/// Generic processing state, not transcription-specific: `pendingTranscription`
/// and `transcribing` mean "queued" and "running" for whichever processor the
/// item's [CaptureType] resolves to (transcription, OCR, text passthrough).
/// The names are kept because renaming ripples through persisted JSON.
enum RecordingStatus {
  saved,
  pendingTranscription,
  transcribing,
  completed,
  failed,
}

/// One item in the queue. Despite the name this covers every [CaptureType] —
/// mic recordings, uploads, images, text notes and video — because they share
/// every field and the whole persistence stack is keyed on one list type.
class Recording {
  const Recording({
    required this.id,
    required this.filePath,
    required this.createdAt,
    required this.durationMs,
    required this.status,
    this.sizeBytes = 0,
    this.type = CaptureType.audioRecording,
    this.sourceMimeType,
    this.transcript,
    this.title,
    this.category,
    this.summary,
    this.tags = const <String>[],
    this.error,
    this.isProcessedByUser = false,
    this.processedAt,
  });

  final String id;
  final String filePath;
  final DateTime createdAt;

  /// Length of the media track; `0` for images and text notes, which the UI
  /// suppresses rather than rendering `00:00`.
  final int durationMs;
  final RecordingStatus status;

  /// Size of the source artifact, measured during the same `length()` check
  /// that verifies the file is non-empty at capture time. `0` on legacy rows,
  /// where the card simply omits the size from its verification footer.
  final int sizeBytes;

  /// Immutable identity, set at construction and never changed by the pipeline.
  final CaptureType type;

  /// Recorded at ingestion so uploads keep their identity (`image/png`,
  /// `audio/mpeg`). Null on legacy rows and on mic captures.
  final String? sourceMimeType;

  /// Processor output text: transcript, OCR result, or the note body. Nullable
  /// until processing completes; this is what the Queue search matches on.
  /// User-editable after processing (never touched by the pipeline once set by
  /// the user — edits and re-processing are distinct paths).
  final String? transcript;

  /// Optional user-set display name. Null on legacy rows and until named; the
  /// card falls back to the filename. Never set by processing.
  final String? title;

  /// What the item *is*, assigned by the enrichment stage and correctable by
  /// the user.
  ///
  /// **Null and [CaptureCategory.capture] are different states.** Null means
  /// enrichment never ran — no profile configured, or the call failed.
  /// `capture` means it ran and could not place the item. Collapsing them would
  /// make an unconfigured install indistinguishable from a failing model.
  final CaptureCategory? category;

  /// One-line gist from the enrichment stage. Null until enriched.
  final String? summary;

  /// Up to five lowercase tags from the enrichment stage. Empty until enriched,
  /// and on every legacy row.
  final List<String> tags;

  final String? error;

  /// User-level state. This is intentionally separate from AI processing.
  final bool isProcessedByUser;
  final DateTime? processedAt;

  Recording copyWith({
    RecordingStatus? status,
    String? transcript,
    String? title,
    bool clearTitle = false,
    CaptureCategory? category,
    bool clearCategory = false,
    String? summary,
    bool clearSummary = false,
    List<String>? tags,
    String? error,
    bool clearError = false,
    bool? isProcessedByUser,
    DateTime? processedAt,
    bool clearProcessedAt = false,
  }) {
    return Recording(
      id: id,
      filePath: filePath,
      createdAt: createdAt,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      type: type,
      sourceMimeType: sourceMimeType,
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      title: clearTitle ? null : (title ?? this.title),
      category: clearCategory ? null : (category ?? this.category),
      summary: clearSummary ? null : (summary ?? this.summary),
      tags: tags ?? this.tags,
      error: clearError ? null : (error ?? this.error),
      isProcessedByUser: isProcessedByUser ?? this.isProcessedByUser,
      processedAt: clearProcessedAt ? null : (processedAt ?? this.processedAt),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'filePath': filePath,
        'createdAt': createdAt.toIso8601String(),
        'durationMs': durationMs,
        'sizeBytes': sizeBytes,
        'status': status.name,
        'type': type.name,
        'sourceMimeType': sourceMimeType,
        'transcript': transcript,
        'title': title,
        'category': category?.name,
        'summary': summary,
        'tags': tags,
        'error': error,
        'isProcessedByUser': isProcessedByUser,
        'processedAt': processedAt?.toIso8601String(),
      };

  factory Recording.fromJson(Map<String, dynamic> json) {
    return Recording(
      id: json['id'] as String,
      filePath: json['filePath'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      durationMs: json['durationMs'] as int,
      // Absent on every row written before the card showed a size.
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      status: RecordingStatus.values.byName(json['status'] as String),
      // Legacy rows have no `type`; unknown names from a newer build degrade
      // the same way rather than throwing.
      type: CaptureType.fromName(json['type'] as String?),
      sourceMimeType: json['sourceMimeType'] as String?,
      transcript: json['transcript'] as String?,
      title: json['title'] as String?,
      // Absent on every row written before enrichment existed. A missing value
      // stays null — "never enriched" — while a *present* unknown name degrades
      // to `capture`, the same forward-compatibility rule as `type`.
      category: json['category'] == null
          ? null
          : CaptureCategory.fromName(json['category'] as String?),
      summary: json['summary'] as String?,
      // Type-filtered rather than cast: a hand-edited recordings.json holding a
      // non-list, or a list with a stray number in it, would otherwise throw out
      // of the whole load and take every other recording with it.
      tags: json['tags'] is List<dynamic>
          ? (json['tags'] as List<dynamic>).whereType<String>().toList()
          : const <String>[],
      error: json['error'] as String?,
      isProcessedByUser: json['isProcessedByUser'] as bool? ?? false,
      processedAt: json['processedAt'] == null
          ? null
          : DateTime.parse(json['processedAt'] as String),
    );
  }
}

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
    this.type = CaptureType.audioRecording,
    this.sourceMimeType,
    this.transcript,
    this.error,
    this.isProcessedByUser = false,
    this.processedAt,
  });

  /// A typed note. The body has already been written to [filePath] and verified
  /// by the caller, so there is nothing left to extract — the item starts
  /// `completed` with the body as its text. It still goes through the normal
  /// persist-then-index path; only the processing step is a passthrough.
  factory Recording.textNote({
    required String id,
    required String filePath,
    required String body,
    required DateTime createdAt,
  }) {
    return Recording(
      id: id,
      filePath: filePath,
      createdAt: createdAt,
      durationMs: 0,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      sourceMimeType: 'text/plain',
      transcript: body,
    );
  }

  final String id;
  final String filePath;
  final DateTime createdAt;

  /// Length of the media track; `0` for images and text notes, which the UI
  /// suppresses rather than rendering `00:00`.
  final int durationMs;
  final RecordingStatus status;

  /// Immutable identity, set at construction and never changed by the pipeline.
  final CaptureType type;

  /// Recorded at ingestion so uploads keep their identity (`image/png`,
  /// `audio/mpeg`). Null on legacy rows and on mic captures.
  final String? sourceMimeType;

  /// Processor output text: transcript, OCR result, or the note body. Nullable
  /// until processing completes; this is what the Queue search matches on.
  final String? transcript;
  final String? error;

  /// User-level state. This is intentionally separate from AI processing.
  final bool isProcessedByUser;
  final DateTime? processedAt;

  Recording copyWith({
    RecordingStatus? status,
    String? transcript,
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
      type: type,
      sourceMimeType: sourceMimeType,
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
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
        'status': status.name,
        'type': type.name,
        'sourceMimeType': sourceMimeType,
        'transcript': transcript,
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
      status: RecordingStatus.values.byName(json['status'] as String),
      // Legacy rows have no `type`; unknown names from a newer build degrade
      // the same way rather than throwing.
      type: CaptureType.fromName(json['type'] as String?),
      sourceMimeType: json['sourceMimeType'] as String?,
      transcript: json['transcript'] as String?,
      error: json['error'] as String?,
      isProcessedByUser: json['isProcessedByUser'] as bool? ?? false,
      processedAt: json['processedAt'] == null
          ? null
          : DateTime.parse(json['processedAt'] as String),
    );
  }
}

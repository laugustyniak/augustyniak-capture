enum RecordingStatus {
  saved,
  pendingTranscription,
  transcribing,
  completed,
  failed,
}

class Recording {
  const Recording({
    required this.id,
    required this.filePath,
    required this.createdAt,
    required this.durationMs,
    required this.status,
    this.transcript,
    this.error,
    this.isProcessedByUser = false,
    this.processedAt,
  });

  final String id;
  final String filePath;
  final DateTime createdAt;
  final int durationMs;
  final RecordingStatus status;
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
      transcript: json['transcript'] as String?,
      error: json['error'] as String?,
      isProcessedByUser: json['isProcessedByUser'] as bool? ?? false,
      processedAt: json['processedAt'] == null
          ? null
          : DateTime.parse(json['processedAt'] as String),
    );
  }
}

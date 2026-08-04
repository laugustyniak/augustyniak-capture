enum LogLevel { info, warn, error }

/// One line in the processing console. Read-only history — nothing in the app
/// mutates an event after it is appended.
class LogEvent {
  const LogEvent({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.message,
    this.recordingId,
  });

  final String id;
  final DateTime timestamp;
  final LogLevel level;
  final String message;

  /// Set when the event belongs to a specific recording, so the Logs tab can
  /// group and the Queue can be cross-referenced by id.
  final String? recordingId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'message': message,
    'recordingId': recordingId,
  };

  factory LogEvent.fromJson(Map<String, dynamic> json) {
    return LogEvent(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      level: _levelFromName(json['level'] as String?),
      message: json['message'] as String? ?? '',
      recordingId: json['recordingId'] as String?,
    );
  }

  /// Unknown or missing levels degrade to `info` instead of throwing, so a log
  /// file written by a newer build still loads.
  static LogLevel _levelFromName(String? name) =>
      LogLevel.values.asNameMap()[name] ?? LogLevel.info;
}

/// Write-only seam used by `RecordingsController`. Defaults to a no-op so the
/// pure-Dart tests need no log store.
abstract interface class LogSink {
  void log(String message, {LogLevel level, String? recordingId});
}

class NoopLogSink implements LogSink {
  const NoopLogSink();

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {}
}

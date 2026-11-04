import '../../recordings/domain/recording.dart';

enum ConnectionKind { sameTopic, complementary, differentAngle, appImprovement }

class ConnectionGroup {
  const ConnectionGroup({
    required this.kind,
    required this.title,
    required this.explanation,
    required this.captureIds,
  });

  final ConnectionKind kind;
  final String title;
  final String explanation;
  final List<String> captureIds;
}

/// What a review covers: one local calendar day, or every capture still open.
class ConnectionsScope {
  const ConnectionsScope.day(DateTime this.day);

  /// Every capture not yet marked done, whatever day it was captured on.
  const ConnectionsScope.open() : day = null;

  /// Null for [ConnectionsScope.open].
  final DateTime? day;

  bool get isOpen => day == null;
}

class DailyConnectionsReport {
  const DailyConnectionsReport({required this.scope, required this.groups});

  final ConnectionsScope scope;
  final List<ConnectionGroup> groups;
}

/// The one selection both the dialog's count and the model's input use.
/// Independent of the Queue's current filters; requires a non-empty transcript.
List<Recording> capturesInScope(
  Iterable<Recording> recordings,
  ConnectionsScope scope,
) => switch (scope.day) {
  final DateTime day => capturesOnDay(recordings, day),
  null => openCaptures(recordings),
};

/// Uses the local calendar day, independent of the Queue's current filters.
List<Recording> capturesOnDay(Iterable<Recording> recordings, DateTime day) =>
    recordings.where((Recording recording) {
      final DateTime captured = recording.createdAt.toLocal();
      return captured.year == day.year &&
          captured.month == day.month &&
          captured.day == day.day &&
          _hasText(recording);
    }).toList();

/// What the Desk filter shows: not marked done, on any day.
List<Recording> openCaptures(Iterable<Recording> recordings) => recordings
    .where(
      (Recording recording) =>
          !recording.isProcessedByUser && _hasText(recording),
    )
    .toList();

bool _hasText(Recording recording) =>
    recording.transcript?.trim().isNotEmpty ?? false;

abstract interface class DailyConnectionsService {
  Future<DailyConnectionsReport> review(
    ConnectionsScope scope,
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  });
}

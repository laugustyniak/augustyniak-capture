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

class DailyConnectionsReport {
  const DailyConnectionsReport({required this.day, required this.groups});

  final DateTime day;
  final List<ConnectionGroup> groups;
}

/// Uses the local calendar day, independent of the Queue's current filters.
List<Recording> capturesOnDay(Iterable<Recording> recordings, DateTime day) =>
    recordings.where((Recording recording) {
      final DateTime captured = recording.createdAt.toLocal();
      return captured.year == day.year &&
          captured.month == day.month &&
          captured.day == day.day &&
          (recording.transcript?.trim().isNotEmpty ?? false);
    }).toList();

abstract interface class DailyConnectionsService {
  Future<DailyConnectionsReport> review(
    DateTime day,
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  });
}

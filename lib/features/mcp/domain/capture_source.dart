import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';

/// Where the MCP tools read captures from. Read-only by construction: there is
/// no write method to implement, which is the whole guarantee of this feature.
///
/// Every call re-reads the store — the app keeps writing while an agent host
/// holds this server open, so a cached list would go stale within minutes.
abstract class CaptureSource {
  /// Newest first. Throws when no store can be found or read at all.
  Future<List<Recording>> recordings();

  /// Same rows and order as [recordings], each with the `json_payload` string
  /// it was read from. A row with no stored string (index path, rebuilt row)
  /// carries `jsonEncode(recording.toJson())` instead.
  Future<List<({Recording recording, String payload})>> recordingsWithPayload();

  Future<List<Project>> projects();
}

/// No store could be found or read at all. [detail] names paths and is for
/// stderr only; what reaches the agent is a fixed message.
class CaptureStoreUnavailable implements Exception {
  CaptureStoreUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'CaptureStoreUnavailable: $detail';
}

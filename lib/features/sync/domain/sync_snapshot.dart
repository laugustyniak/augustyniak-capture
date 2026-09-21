/// What the server last acknowledged for one local row.
class SyncRowState {
  const SyncRowState({required this.serverVersion, required this.pushedHash});

  final int serverVersion;
  final String pushedHash;
}

/// Device-local sync bookkeeping: the server version and pushed-content hash
/// last recorded per row, plus a per-table pull cursor. A later task adds
/// more classes to this file.
abstract interface class SyncBookkeeping {
  Map<String, SyncRowState> loadTable(String table);
  void put(String table, String id, int serverVersion, String pushedHash);
  void remove(String table, String id);
  DateTime? cursor(String table);
  void setCursor(String table, DateTime value);
}

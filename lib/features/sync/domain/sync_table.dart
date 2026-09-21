/// The seven server tables and the columns that key each one — the same
/// list `sync_push` validates against. Column names and keys mirror
/// `supabase/migrations/20260920190000_user_owned_metadata.sql`.
enum SyncTable {
  projects('projects', <String>['id']),
  recordings('recordings', <String>['id']),
  segments('segments', <String>['recording_id', 'index']),
  clipboardItems('clipboard_items', <String>['id']),
  revisions('revisions', <String>['recording_id', 'at', 'field']),
  devices('devices', <String>['id']),
  syncState('sync_state', <String>['device_id', 'table_name']);

  const SyncTable(this.serverName, this.keyColumns);

  /// The Postgres table name. Deliberately not called `name` — the enum's
  /// built-in `name` getter already answers the Dart member name
  /// (`clipboardItems`), and this is the server spelling
  /// (`clipboard_items`); reusing the getter's name would shadow it and
  /// invite exactly that confusion.
  final String serverName;
  final List<String> keyColumns;

  /// Versioned tables take the conflict gate; revisions are append-only.
  bool get versioned => this != SyncTable.revisions;
}

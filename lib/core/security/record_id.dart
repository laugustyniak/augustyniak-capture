/// Whether [id] can be used as a single path segment, a URL segment or a
/// shell argument without escaping.
///
/// Every id this app generates is a UUID v4, which passes. Ids also arrive
/// from sync rows and from backup archives, and an id later names a file
/// (`.agent-tasks/<id>.md`) and a directory an agent runs in. `..`, a
/// separator, an absolute path, an empty string or an oversize value is
/// refused at those boundaries (#292) and at the handoff sink (#290).
bool isSafeRecordId(String id) => _safeRecordId.hasMatch(id);

final RegExp _safeRecordId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

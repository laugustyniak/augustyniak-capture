import 'dart:async';

import 'package:augustyniak_capture/features/sync/domain/e2ee_settings_store.dart';

/// `user_e2ee_settings` in a map: insert-only like the real table, with the
/// two failure shapes the flow has to survive — a read that throws
/// ([readError]) and one that never answers ([readGate]).
class FakeE2eeSettingsStore implements E2eeSettingsStore {
  final Map<String, E2eePublicParams> rows = <String, E2eePublicParams>{};
  Object? readError;
  Object? createError;
  Completer<void>? readGate;
  Completer<void>? createGate;
  int reads = 0;
  int creates = 0;

  @override
  Future<E2eePublicParams?> read(String ownerId) async {
    reads += 1;
    // Snapshot first: a gated read answers what the server knew when the
    // request left, which is what makes it stale by the time it lands.
    final E2eePublicParams? answer = rows[ownerId];
    if (readGate case final Completer<void> gate) await gate.future;
    if (readError case final Object error) throw error;
    return answer;
  }

  @override
  Future<void> create(String ownerId, E2eePublicParams params) async {
    creates += 1;
    if (createGate case final Completer<void> gate) await gate.future;
    if (createError case final Object error) throw error;
    if (rows.containsKey(ownerId)) throw const E2eeSettingsConflictException();
    rows[ownerId] = params;
  }
}

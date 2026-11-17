import 'package:augustyniak_capture/features/sync/domain/sync_binding.dart';

/// In-memory `sync.owner` plus a stand-in for "the ledger holds rows".
class FakeSyncBindingStore implements SyncBindingStore {
  SyncOwnerRead owner = const SyncOwnerAbsent();
  bool ledgerRows = false;
  bool readThrows = false;
  int binds = 0;
  int unbinds = 0;

  @override
  SyncOwnerRead readOwner() {
    if (readThrows) throw StateError('settings unreadable');
    return owner;
  }

  @override
  bool hasLedgerRows() => ledgerRows;

  @override
  void bindOwner({required String id, required String email}) {
    binds += 1;
    owner = SyncOwnerBound(id: id, email: email);
  }

  @override
  void unbind() {
    unbinds += 1;
    owner = const SyncOwnerAbsent();
    ledgerRows = false;
  }
}

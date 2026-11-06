/// Which account this device's library belongs to (#206).
///
/// The `sync_rows` ledger and the `sync.cursor.*` keys describe what *one*
/// account's server already holds. Without an owner beside them, a second
/// account signing in on the same device would see rows already pushed as
/// clean and receive a partial copy of the first account's library. So the
/// ledger carries a `sync.owner`, and every run passes a gate that compares
/// it with the signed-in identity before any push, pull or Storage call.
library;

/// What reading `sync.owner` found. Three outcomes, not two: an unreadable
/// owner is never taken for an unbound device, since binding over it could
/// hand one account's ledger to another.
sealed class SyncOwnerRead {
  const SyncOwnerRead();
}

final class SyncOwnerAbsent extends SyncOwnerRead {
  const SyncOwnerAbsent();
}

final class SyncOwnerBound extends SyncOwnerRead {
  const SyncOwnerBound({required this.id, required this.email});

  final String id;

  /// Shown on the Account card so a mismatch names the account to sign in
  /// as. Informational only — the comparison is on [id].
  final String email;
}

final class SyncOwnerUnreadable extends SyncOwnerRead {
  const SyncOwnerUnreadable();
}

/// Device-local storage for the binding, beside the ledger it guards.
abstract interface class SyncBindingStore {
  SyncOwnerRead readOwner();

  /// Whether `sync_rows` holds anything — a device that synced before the
  /// binding existed.
  bool hasLedgerRows();

  void bindOwner({required String id, required String email});

  /// Clears `sync_rows`, every `sync.cursor.*` key and `sync.owner` in one
  /// transaction, and nothing else.
  void unbind();
}

enum SyncBindingStatus {
  /// Nobody is signed in; sync does not run at all.
  signedOut,

  /// Signed in, nothing bound yet, and no run has asked.
  unbound,

  /// A run found local data on an unbound device and is waiting for the
  /// user to confirm uploading it to the signed-in account.
  awaitingConfirmation,

  /// Bound to the signed-in account; runs proceed.
  bound,

  /// Bound to another account; runs are paused.
  mismatch,

  /// `sync.owner` could not be read; runs are paused as for a mismatch.
  unreadable,
}

class SyncBindingState {
  const SyncBindingState(this.status, {this.boundEmail});

  static const SyncBindingState signedOut = SyncBindingState(
    SyncBindingStatus.signedOut,
  );

  final SyncBindingStatus status;
  final String? boundEmail;
}

/// The gate's answer for one run. [reason] is the slot's `failureReason`
/// when the run is paused.
class SyncGateDecision {
  const SyncGateDecision.proceed() : reason = null;

  const SyncGateDecision.paused(String this.reason);

  final String? reason;

  bool get proceed => reason == null;
}

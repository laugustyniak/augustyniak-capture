import 'package:flutter/foundation.dart';

import '../../auth/domain/auth_identity.dart';
import '../domain/sync_binding.dart';

/// Binds this device's library to one account before Supabase sync (#206).
///
/// [gate] runs at the top of every sync run, before the transport or the
/// media store is resolved, so a paused run makes no push, pull or Storage
/// call at all. The rules, in order:
///
/// - bound to the signed-in account → proceed;
/// - bound to another account, or `sync.owner` unreadable → paused;
/// - unbound, and the ledger already holds rows (synced before this change)
///   or the library is empty → bind silently and proceed;
/// - unbound with local data → paused until [confirmUpload].
///
/// The Account card reads [state] and offers [confirmUpload] and [unbind].
class SyncBindingController extends ChangeNotifier {
  SyncBindingController({required Future<SyncBindingStore> Function() store})
    : _store = store;

  final Future<SyncBindingStore> Function() _store;

  SyncBindingState _state = SyncBindingState.signedOut;
  AuthIdentity? _identity;
  bool _disposed = false;

  SyncBindingState get state => _state;

  /// Refreshes [state] for [identity] without binding anything. Called by
  /// the shell on every auth change.
  Future<void> followIdentity(AuthIdentity? identity) async {
    final bool sameAccount = identity?.id == _identity?.id;
    _identity = identity;
    if (identity == null) {
      _set(SyncBindingState.signedOut);
      return;
    }
    final SyncOwnerRead owner = await _readOwner();
    if (_identity?.id != identity.id) return;
    if (owner is SyncOwnerAbsent &&
        sameAccount &&
        _state.status == SyncBindingStatus.awaitingConfirmation) {
      // A run already asked; keep the prompt rather than downgrading it.
      return;
    }
    _set(_stateFor(owner, identity));
  }

  Future<SyncGateDecision> gate(
    AuthIdentity identity, {
    required bool libraryIsEmpty,
  }) async {
    _identity = identity;
    final SyncBindingStore store;
    try {
      store = await _store();
    } catch (_) {
      _set(const SyncBindingState(SyncBindingStatus.unreadable));
      return const SyncGateDecision.paused(_unreadableReason);
    }
    final SyncOwnerRead owner = _read(store);
    switch (owner) {
      case SyncOwnerBound(:final String id, :final String email):
        if (id == identity.id) {
          _set(SyncBindingState(SyncBindingStatus.bound, boundEmail: email));
          return const SyncGateDecision.proceed();
        }
        _set(SyncBindingState(SyncBindingStatus.mismatch, boundEmail: email));
        return SyncGateDecision.paused(
          'sync paused: this library belongs to ${_label(email)}; sign in '
          'with that account, or unbind this device in Config',
        );
      case SyncOwnerUnreadable():
        _set(const SyncBindingState(SyncBindingStatus.unreadable));
        return const SyncGateDecision.paused(_unreadableReason);
      case SyncOwnerAbsent():
        bool legacy;
        try {
          legacy = store.hasLedgerRows();
        } catch (_) {
          // Unknown history must not be uploaded without a yes.
          legacy = false;
          libraryIsEmpty = false;
        }
        if (legacy || libraryIsEmpty) {
          try {
            store.bindOwner(id: identity.id, email: identity.email);
          } catch (_) {
            _set(const SyncBindingState(SyncBindingStatus.unreadable));
            return const SyncGateDecision.paused(_unreadableReason);
          }
          _set(
            SyncBindingState(
              SyncBindingStatus.bound,
              boundEmail: identity.email,
            ),
          );
          return const SyncGateDecision.proceed();
        }
        _set(const SyncBindingState(SyncBindingStatus.awaitingConfirmation));
        return SyncGateDecision.paused(
          'sync paused: confirm UPLOAD THIS LIBRARY in Config to sync this '
          "device's library to ${_label(identity.email)}",
        );
    }
  }

  /// Binds an unbound device to the signed-in account. Refused (false) when
  /// nobody is signed in or the device is already bound — moving a library
  /// to another account is not this action.
  Future<bool> confirmUpload() async {
    final AuthIdentity? identity = _identity;
    if (identity == null) return false;
    try {
      final SyncBindingStore store = await _store();
      if (_read(store) is! SyncOwnerAbsent) {
        _set(_stateFor(_read(store), identity));
        return false;
      }
      store.bindOwner(id: identity.id, email: identity.email);
    } catch (_) {
      return false;
    }
    _set(SyncBindingState(SyncBindingStatus.bound, boundEmail: identity.email));
    return true;
  }

  /// Clears the ledger, the cursors and the binding in one transaction.
  /// Local recordings, projects, clipboard items and source files are not
  /// touched; the next run on a non-empty library asks again.
  Future<bool> unbind() async {
    try {
      final SyncBindingStore store = await _store();
      store.unbind();
    } catch (_) {
      return false;
    }
    _set(
      _identity == null
          ? SyncBindingState.signedOut
          : const SyncBindingState(SyncBindingStatus.unbound),
    );
    return true;
  }

  static const String _unreadableReason =
      "sync paused: this device's account binding could not be read; unbind "
      'this device in Config to start over';

  static String _label(String email) =>
      email.isEmpty ? 'another account' : email;

  Future<SyncOwnerRead> _readOwner() async {
    try {
      return _read(await _store());
    } catch (_) {
      return const SyncOwnerUnreadable();
    }
  }

  static SyncOwnerRead _read(SyncBindingStore store) {
    try {
      return store.readOwner();
    } catch (_) {
      return const SyncOwnerUnreadable();
    }
  }

  static SyncBindingState _stateFor(
    SyncOwnerRead owner,
    AuthIdentity identity,
  ) => switch (owner) {
    SyncOwnerAbsent() => const SyncBindingState(SyncBindingStatus.unbound),
    SyncOwnerUnreadable() => const SyncBindingState(
      SyncBindingStatus.unreadable,
    ),
    SyncOwnerBound(:final String id, :final String email) => SyncBindingState(
      id == identity.id ? SyncBindingStatus.bound : SyncBindingStatus.mismatch,
      boundEmail: email,
    ),
  };

  void _set(SyncBindingState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

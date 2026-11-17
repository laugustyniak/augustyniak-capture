import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_binding.dart';
import 'package:augustyniak_capture/features/sync/presentation/sync_binding_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_binding_store.dart';

/// #206: which account this device's library belongs to, and the gate every
/// sync run passes before anything reaches the server.
void main() {
  const AuthIdentity a = AuthIdentity(id: 'owner-a', email: 'a@example.com');
  const AuthIdentity b = AuthIdentity(id: 'owner-b', email: 'b@example.com');

  late FakeSyncBindingStore store;
  late SyncBindingController binding;

  setUp(() {
    store = FakeSyncBindingStore();
    binding = SyncBindingController(store: () async => store);
  });

  tearDown(() => binding.dispose());

  test(
    'an empty library on an unbound device binds silently and proceeds',
    () async {
      final SyncGateDecision decision = await binding.gate(
        a,
        libraryIsEmpty: true,
      );
      expect(decision.proceed, isTrue);
      expect(store.owner, isA<SyncOwnerBound>());
      expect((store.owner as SyncOwnerBound).id, 'owner-a');
      expect(binding.state.status, SyncBindingStatus.bound);
    },
  );

  test(
    'a non-empty library on an unbound device pauses until confirmed',
    () async {
      final SyncGateDecision decision = await binding.gate(
        a,
        libraryIsEmpty: false,
      );
      expect(decision.proceed, isFalse);
      expect(decision.reason, contains('a@example.com'));
      expect(
        store.owner,
        isA<SyncOwnerAbsent>(),
        reason: 'nothing bound without a yes',
      );
      expect(binding.state.status, SyncBindingStatus.awaitingConfirmation);

      await binding.followIdentity(a);
      expect(
        binding.state.status,
        SyncBindingStatus.awaitingConfirmation,
        reason: 'a refresh for the same account keeps the pending prompt',
      );

      expect(await binding.confirmUpload(), isTrue);
      expect((store.owner as SyncOwnerBound).id, 'owner-a');
      expect(binding.state.status, SyncBindingStatus.bound);
      expect((await binding.gate(a, libraryIsEmpty: false)).proceed, isTrue);
    },
  );

  test(
    'a device that synced before #206 binds to the signed-in account without a prompt',
    () async {
      store.ledgerRows = true;
      final SyncGateDecision decision = await binding.gate(
        a,
        libraryIsEmpty: false,
      );
      expect(decision.proceed, isTrue);
      expect((store.owner as SyncOwnerBound).id, 'owner-a');
    },
  );

  test('a different account pauses and names the bound one', () async {
    store.owner = const SyncOwnerBound(id: 'owner-a', email: 'a@example.com');
    final SyncGateDecision decision = await binding.gate(
      b,
      libraryIsEmpty: true,
    );
    expect(decision.proceed, isFalse);
    expect(decision.reason, contains('a@example.com'));
    expect(binding.state.status, SyncBindingStatus.mismatch);
    expect(binding.state.boundEmail, 'a@example.com');
    expect(
      (store.owner as SyncOwnerBound).id,
      'owner-a',
      reason: 'never rebound',
    );

    expect(
      await binding.confirmUpload(),
      isFalse,
      reason: 'adopting into another account is out of scope',
    );
    expect((store.owner as SyncOwnerBound).id, 'owner-a');
  });

  test('an unreadable binding is a mismatch, never unbound', () async {
    store.owner = const SyncOwnerUnreadable();
    for (final bool empty in <bool>[true, false]) {
      final SyncGateDecision decision = await binding.gate(
        a,
        libraryIsEmpty: empty,
      );
      expect(decision.proceed, isFalse);
      expect(
        store.binds,
        0,
        reason: 'an unreadable owner must not be overwritten',
      );
    }
    expect(binding.state.status, SyncBindingStatus.unreadable);
    expect(await binding.confirmUpload(), isFalse);
    expect(store.binds, 0);
  });

  test(
    'a store that throws on read pauses like an unreadable binding',
    () async {
      store.readThrows = true;
      final SyncGateDecision decision = await binding.gate(
        a,
        libraryIsEmpty: true,
      );
      expect(decision.proceed, isFalse);
      expect(store.binds, 0);
      expect(binding.state.status, SyncBindingStatus.unreadable);
    },
  );

  test('a store that cannot be opened pauses', () async {
    final SyncBindingController broken = SyncBindingController(
      store: () async => throw StateError('no database'),
    );
    addTearDown(broken.dispose);
    final SyncGateDecision decision = await broken.gate(
      a,
      libraryIsEmpty: true,
    );
    expect(decision.proceed, isFalse);
  });

  test('unbind clears the binding and the next sign-in starts over', () async {
    store.owner = const SyncOwnerBound(id: 'owner-a', email: 'a@example.com');
    store.ledgerRows = true;
    await binding.followIdentity(b);
    expect(binding.state.status, SyncBindingStatus.mismatch);

    expect(await binding.unbind(), isTrue);
    expect(store.unbinds, 1);
    expect(store.owner, isA<SyncOwnerAbsent>());
    expect(binding.state.status, SyncBindingStatus.unbound);

    final SyncGateDecision decision = await binding.gate(
      b,
      libraryIsEmpty: false,
    );
    expect(
      decision.proceed,
      isFalse,
      reason: 'B still has to confirm the upload',
    );
  });

  test('followIdentity reports signed-out, bound and unbound', () async {
    await binding.followIdentity(null);
    expect(binding.state.status, SyncBindingStatus.signedOut);
    await binding.followIdentity(a);
    expect(binding.state.status, SyncBindingStatus.unbound);
    store.owner = const SyncOwnerBound(id: 'owner-a', email: 'a@example.com');
    await binding.followIdentity(a);
    expect(binding.state.status, SyncBindingStatus.bound);
    expect(binding.state.boundEmail, 'a@example.com');
  });
}

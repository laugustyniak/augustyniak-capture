import 'dart:async';

import 'package:augustyniak_capture/features/auth/domain/auth_gateway.dart';
import 'package:augustyniak_capture/features/auth/domain/auth_identity.dart';
import 'package:augustyniak_capture/features/auth/presentation/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({this.currentIdentity});

  final StreamController<AuthIdentity?> changes =
      StreamController<AuthIdentity?>.broadcast();

  @override
  AuthIdentity? currentIdentity;

  bool launchResult = true;
  Object? launchError;
  bool signedOut = false;

  @override
  Stream<AuthIdentity?> get identityChanges => changes.stream;

  @override
  Future<bool> signInWithGoogle() async {
    if (launchError case final Object error) throw error;
    return launchResult;
  }

  @override
  Future<void> signOut() async {
    signedOut = true;
  }

  Future<void> emit(AuthIdentity? identity) async {
    currentIdentity = identity;
    changes.add(identity);
    await pumpEventQueue();
  }

  Future<void> close() => changes.close();
}

void main() {
  const AuthIdentity user = AuthIdentity(
    id: '3c79b2e4-9988-4e5a-9b88-25159c65fdd2',
    email: 'owner@example.com',
    displayName: 'Owner',
  );

  test(
    'starts with the session already restored from secure storage',
    () async {
      final _FakeAuthGateway gateway = _FakeAuthGateway(currentIdentity: user);
      final AuthController controller = AuthController(gateway)..initialize();

      expect(controller.identity, user);
      expect(controller.isSignedIn, isTrue);

      controller.dispose();
      await gateway.close();
    },
  );

  test('follows later auth changes from the Supabase client', () async {
    final _FakeAuthGateway gateway = _FakeAuthGateway();
    final AuthController controller = AuthController(gateway)..initialize();

    await gateway.emit(user);
    expect(controller.identity, user);

    await gateway.emit(null);
    expect(controller.isSignedIn, isFalse);

    controller.dispose();
    await gateway.close();
  });

  test('reports when the browser could not be opened', () async {
    final _FakeAuthGateway gateway = _FakeAuthGateway()..launchResult = false;
    final AuthController controller = AuthController(gateway)..initialize();

    await controller.signInWithGoogle();

    expect(controller.error, 'Could not open the Google sign-in page.');
    expect(controller.isBusy, isFalse);

    controller.dispose();
    await gateway.close();
  });

  test(
    'sign out delegates to Supabase without inventing local auth state',
    () async {
      final _FakeAuthGateway gateway = _FakeAuthGateway(currentIdentity: user);
      final AuthController controller = AuthController(gateway)..initialize();

      await controller.signOut();

      expect(gateway.signedOut, isTrue);
      expect(controller.identity, user);

      controller.dispose();
      await gateway.close();
    },
  );
}

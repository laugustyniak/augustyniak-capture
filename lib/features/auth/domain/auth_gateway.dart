import 'auth_identity.dart';

abstract interface class AuthGateway {
  AuthIdentity? get currentIdentity;

  Stream<AuthIdentity?> get identityChanges;

  Future<bool> signInWithGoogle();

  Future<void> signOut();
}

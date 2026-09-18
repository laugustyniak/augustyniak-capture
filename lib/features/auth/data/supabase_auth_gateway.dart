import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/auth_gateway.dart';
import '../domain/auth_identity.dart';
import '../domain/auth_redirect.dart';

class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(SupabaseClient client) : _auth = client.auth;

  final GoTrueClient _auth;

  @override
  AuthIdentity? get currentIdentity => _identityFor(_auth.currentUser);

  @override
  Stream<AuthIdentity?> get identityChanges => _auth.onAuthStateChange.map(
    (AuthState state) => _identityFor(state.session?.user),
  );

  @override
  Future<bool> signInWithGoogle() => _auth.signInWithOAuth(
    OAuthProvider.google,
    redirectTo: kIsWeb ? null : AuthRedirect.native.toString(),
  );

  @override
  Future<void> signOut() => _auth.signOut();

  static AuthIdentity? _identityFor(User? user) {
    if (user == null) return null;
    final Object? rawName =
        user.userMetadata?['full_name'] ?? user.userMetadata?['name'];
    final String? displayName = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : null;
    return AuthIdentity(
      id: user.id,
      email: user.email ?? 'Google account',
      displayName: displayName,
    );
  }
}

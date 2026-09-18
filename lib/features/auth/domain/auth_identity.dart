class AuthIdentity {
  const AuthIdentity({required this.id, required this.email, this.displayName});

  final String id;
  final String email;
  final String? displayName;
}

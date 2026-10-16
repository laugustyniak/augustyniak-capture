import 'dart:convert';

/// Public build-time configuration for the optional Supabase backend.
///
/// Neither value is a secret. Server credentials such as `service_role` never
/// belong in this class or in a released client.
class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.publishableKey});

  static const String _url = String.fromEnvironment('SUPABASE_URL');
  static const String _publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const String _nextPublicUrl = String.fromEnvironment(
    'NEXT_PUBLIC_SUPABASE_URL',
  );
  static const String _nextPublicPublishableKey = String.fromEnvironment(
    'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY',
  );

  final String url;
  final String publishableKey;

  static SupabaseConfig? fromEnvironment() => resolve(
    url: _url,
    publishableKey: _publishableKey,
    nextPublicUrl: _nextPublicUrl,
    nextPublicPublishableKey: _nextPublicPublishableKey,
  );

  static SupabaseConfig? resolve({
    required String url,
    required String publishableKey,
    required String nextPublicUrl,
    required String nextPublicPublishableKey,
  }) =>
      parse(url: url, publishableKey: publishableKey) ??
      parse(url: nextPublicUrl, publishableKey: nextPublicPublishableKey);

  static SupabaseConfig? parse({
    required String url,
    required String publishableKey,
  }) => _check(url, publishableKey).config;

  /// Why [parse] answered null, in one short human-readable line, or null when
  /// it did not refuse. Mirrors `TokenCipher.unavailableReason`: the Config tab
  /// shows it so a wrong define is diagnosed in the app, not in a log. Never
  /// contains the key.
  static String? parseIssue({
    required String url,
    required String publishableKey,
  }) => _check(url, publishableKey).issue;

  /// The issue for the pair the user actually set. The Flutter pair is looked
  /// at first, so when both pairs are set the issue names that one even if
  /// [resolve] fell back to the other. A build with no values at all is "not
  /// configured", which is not an issue, so null.
  static String? resolveIssue({
    required String url,
    required String publishableKey,
    required String nextPublicUrl,
    required String nextPublicPublishableKey,
  }) {
    if (url.trim().isNotEmpty || publishableKey.trim().isNotEmpty) {
      return parseIssue(url: url, publishableKey: publishableKey);
    }
    return parseIssue(
      url: nextPublicUrl,
      publishableKey: nextPublicPublishableKey,
    );
  }

  static String? environmentIssue() => resolveIssue(
    url: _url,
    publishableKey: _publishableKey,
    nextPublicUrl: _nextPublicUrl,
    nextPublicPublishableKey: _nextPublicPublishableKey,
  );

  static ({SupabaseConfig? config, String? issue}) _check(
    String url,
    String publishableKey,
  ) {
    final String cleanUrl = url.trim();
    final String cleanKey = publishableKey.trim();
    if (cleanUrl.isEmpty && cleanKey.isEmpty) return (config: null, issue: null);
    if (cleanUrl.isEmpty || cleanKey.isEmpty) {
      return (
        config: null,
        issue: 'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must both be set.',
      );
    }
    if (cleanKey.startsWith('sb_secret_')) {
      return (
        config: null,
        issue:
            'SUPABASE_PUBLISHABLE_KEY is a server-side secret key '
            '(sb_secret_…); use the publishable key.',
      );
    }
    if (cleanKey.startsWith('eyJ')) {
      if (cleanKey.split('.').length != 3) {
        return (
          config: null,
          issue:
              'SUPABASE_PUBLISHABLE_KEY looks like a JWT but is not one (a '
              'JWT has three dot-separated segments).',
        );
      }
      final ({bool readable, String? role}) jwt = _jwtRole(cleanKey);
      if (!jwt.readable) {
        return (
          config: null,
          issue:
              'SUPABASE_PUBLISHABLE_KEY looks like a JWT but its payload '
              'could not be read.',
        );
      }
      final String? role = jwt.role;
      if (role == null) {
        return (
          config: null,
          issue:
              'SUPABASE_PUBLISHABLE_KEY is a JWT with no role claim; use the '
              'anon or publishable key.',
        );
      }
      if (role != 'anon') {
        // The role is echoed only when it is a plain word: the claim is
        // attacker-shaped input like the rest of the token.
        final String shown = RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(role)
            ? role
            : 'not anon';
        return (
          config: null,
          issue:
              'SUPABASE_PUBLISHABLE_KEY is a JWT whose role is $shown; use '
              'the anon or publishable key.',
        );
      }
    }

    final Uri? endpoint = Uri.tryParse(cleanUrl);
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      return (
        config: null,
        issue:
            'SUPABASE_URL must be the bare project URL '
            '(https://<ref>.supabase.co).',
      );
    }

    final bool secure = endpoint.scheme == 'https';
    final bool localHttp =
        endpoint.scheme == 'http' &&
        const <String>{'localhost', '127.0.0.1', '::1'}.contains(endpoint.host);
    if (!secure && !localHttp) {
      return (
        config: null,
        issue:
            'SUPABASE_URL must use https (http is allowed for localhost '
            'only).',
      );
    }

    return (
      config: SupabaseConfig(
        url: endpoint.replace(path: '').toString(),
        publishableKey: cleanKey,
      ),
      issue: null,
    );
  }

  /// Reads the `role` claim of a three-segment JWT. The signature is not
  /// verified: the check is on the claim this build is about to ship, not on
  /// authenticity. A payload that is not a JSON object, or whose `role` is not
  /// a string, counts as unreadable rather than as some role.
  static ({bool readable, String? role}) _jwtRole(String token) {
    try {
      final List<String> parts = token.split('.');
      final Object? payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map) return (readable: false, role: null);
      final Object? role = payload['role'];
      if (role != null && role is! String) return (readable: false, role: null);
      return (readable: true, role: role as String?);
    } catch (_) {
      return (readable: false, role: null);
    }
  }
}

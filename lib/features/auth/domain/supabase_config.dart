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

  final String url;
  final String publishableKey;

  static SupabaseConfig? fromEnvironment() =>
      parse(url: _url, publishableKey: _publishableKey);

  static SupabaseConfig? parse({
    required String url,
    required String publishableKey,
  }) {
    final String cleanUrl = url.trim();
    final String cleanKey = publishableKey.trim();
    if (cleanUrl.isEmpty ||
        cleanKey.isEmpty ||
        cleanKey.startsWith('sb_secret_')) {
      return null;
    }

    final Uri? endpoint = Uri.tryParse(cleanUrl);
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      return null;
    }

    final bool secure = endpoint.scheme == 'https';
    final bool localHttp =
        endpoint.scheme == 'http' &&
        const <String>{'localhost', '127.0.0.1', '::1'}.contains(endpoint.host);
    if (!secure && !localHttp) return null;

    return SupabaseConfig(
      url: endpoint.replace(path: '').toString(),
      publishableKey: cleanKey,
    );
  }
}

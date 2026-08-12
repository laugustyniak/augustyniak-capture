/// Which addresses this app is willing to hand a sync bearer token to.
///
/// Every libsql pipeline call carries `Authorization: Bearer …` **and** the
/// batch of captures being pushed, so the address is not a preference: an
/// `http://` host receives both in the clear, and a `file:`/`javascript:` value
/// is not a network address at all. `Uri.hasScheme` — the check the rest of the
/// app uses for a *provider* endpoint — is too weak here for the same reason
/// it was too weak there, and this is the place a pairing code is believed.
class SyncEndpoint {
  const SyncEndpoint._();

  /// The two schemes Turso speaks. `libsql://` is rewritten to `https://` when
  /// the request is built; both are TLS.
  static const Set<String> allowedSchemes = <String>{'libsql', 'https'};

  /// The address as it should be stored, or null when it must not be used.
  ///
  /// Blank is null rather than invalid: an unconfigured install and a refused
  /// address answer the same way to a caller that only asks "can I sync", and
  /// the callers that need to tell them apart look at the raw field.
  static String? normalize(String? raw) {
    final String trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (!allowedSchemes.contains(uri.scheme.toLowerCase())) return null;
    if (uri.host.isEmpty) return null;
    return trimmed;
  }

  /// Host of an acceptable address, or null. This is what a confirmation
  /// prompt shows: a token says nothing to a reader, a hostname says whose
  /// database is about to receive every capture.
  static String? hostOf(String? raw) {
    final String? normalized = normalize(raw);
    if (normalized == null) return null;
    return Uri.parse(normalized).host;
  }

  /// [normalize], further restricted to TLS-over-HTTP — R2 speaks S3 over
  /// https and nothing else.
  static String? normalizeHttps(String? raw) {
    final String? normalized = normalize(raw);
    if (normalized == null) return null;
    return Uri.parse(normalized).scheme.toLowerCase() == 'https'
        ? normalized
        : null;
  }
}

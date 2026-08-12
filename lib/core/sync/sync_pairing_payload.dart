import 'dart:convert';

import 'sync_endpoint.dart';

/// The contents of a pairing QR code, once it has been proven well-formed.
///
/// **Parsing is separated from applying deliberately.** A QR code is input from
/// whatever happened to be in front of the camera — a poster, a screen, an
/// image in a chat — and applying one repoints the sync destination for every
/// future capture. So the scanner's job is to produce this object, the user's
/// job is to confirm the [host] it names, and only then does anything reach
/// `SettingsController`. The scanner used to do all three at once.
class SyncPairingPayload {
  const SyncPairingPayload({
    required this.tursoDbUrl,
    required this.tursoAuthToken,
    this.r2Endpoint,
    this.r2Bucket,
    this.r2AccessKeyId,
    this.r2SecretAccessKey,
  });

  /// The `type` field every pairing code carries, and the only value accepted.
  static const String typeMarker = 'augustyniak_sync_v1';

  final String tursoDbUrl;
  final String tursoAuthToken;
  final String? r2Endpoint;
  final String? r2Bucket;
  final String? r2AccessKeyId;
  final String? r2SecretAccessKey;

  /// Whose database this is — the one fact worth putting in a confirmation.
  String get host => Uri.parse(tursoDbUrl).host;

  /// Whether the code configures media storage as well as the index. R2 needs
  /// all four fields; three of them configure nothing that can be reached.
  bool get hasR2 =>
      r2Endpoint != null &&
      r2Bucket != null &&
      r2AccessKeyId != null &&
      r2SecretAccessKey != null;

  /// The payload, or null when this is not a pairing code this app will act on.
  ///
  /// Null covers every rejection — malformed JSON, another application's code,
  /// a missing token, an address that would carry the token in the clear —
  /// because the scanner does the same thing with all of them: keep scanning.
  static SyncPairingPayload? parse(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['type'] != typeMarker) return null;

    final String? url = SyncEndpoint.normalize(_text(decoded['tursoDbUrl']));
    if (url == null) return null;
    final String? token = _text(decoded['tursoAuthToken']);
    if (token == null) return null;

    // The R2 half is optional, but a *present* endpoint has to be acceptable:
    // the secret access key travels in the same code, so dropping a bad
    // endpoint silently would leave the key configured against nothing while
    // the pairing still reported success.
    final String? rawR2 = _text(decoded['r2Endpoint']);
    final String? r2Endpoint = rawR2 == null
        ? null
        : SyncEndpoint.normalizeHttps(rawR2);
    if (rawR2 != null && r2Endpoint == null) return null;

    return SyncPairingPayload(
      tursoDbUrl: url,
      tursoAuthToken: token,
      r2Endpoint: r2Endpoint,
      r2Bucket: _text(decoded['r2Bucket']),
      r2AccessKeyId: _text(decoded['r2AccessKeyId']),
      r2SecretAccessKey: _text(decoded['r2SecretAccessKey']),
    );
  }

  /// A trimmed non-empty string, or null — a blank field in a QR code means
  /// the sender had nothing to give, exactly like an absent one.
  static String? _text(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

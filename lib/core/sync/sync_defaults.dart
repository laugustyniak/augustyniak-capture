/// Build-time seed values for the Turso and R2 sync credentials.
///
/// **These were literals in the source until they were found in a public
/// repository.** A working Turso JWT and an R2 secret access key sat inlined in
/// four files — the settings repository, the config tab, the QR pairing sheet
/// and the recordings controller — each one a separate copy that had to be
/// found before the keys could be rotated. Anything committed here is public
/// the moment it is pushed, and stays reachable through `refs/pull/*` long
/// after the commit that removed it, so a rotation is the only real fix and
/// re-adding a literal here undoes it.
///
/// Empty is the normal state: an install with no `--dart-define` simply has no
/// sync configured until the Config tab or a QR pairing fills it in, which is
/// exactly how the transcription token has always behaved. The defines exist
/// so a personal build can still come up pre-paired:
///
/// ```
/// flutter run --dart-define=TURSO_DB_URL=libsql://… \
///             --dart-define=TURSO_AUTH_TOKEN=… \
///             --dart-define=R2_SECRET_ACCESS_KEY=…
/// ```
///
/// Every getter answers null rather than '' when unset, so call sites keep
/// using `??` and a blank define cannot be mistaken for a configured endpoint.
class SyncDefaults {
  const SyncDefaults._();

  static const String _tursoDbUrl = String.fromEnvironment('TURSO_DB_URL');
  static const String _tursoAuthToken =
      String.fromEnvironment('TURSO_AUTH_TOKEN');
  static const String _r2Endpoint = String.fromEnvironment('R2_ENDPOINT');
  static const String _r2Bucket = String.fromEnvironment('R2_BUCKET');
  static const String _r2AccessKeyId =
      String.fromEnvironment('R2_ACCESS_KEY_ID');
  static const String _r2SecretAccessKey =
      String.fromEnvironment('R2_SECRET_ACCESS_KEY');

  static String? get tursoDbUrl => _orNull(_tursoDbUrl);
  static String? get tursoAuthToken => _orNull(_tursoAuthToken);
  static String? get r2Endpoint => _orNull(_r2Endpoint);
  static String? get r2Bucket => _orNull(_r2Bucket);
  static String? get r2AccessKeyId => _orNull(_r2AccessKeyId);
  static String? get r2SecretAccessKey => _orNull(_r2SecretAccessKey);

  /// True when this build carries enough to reach Turso without the user
  /// configuring anything. The two halves are useless apart.
  static bool get hasTurso => tursoDbUrl != null && tursoAuthToken != null;

  static String? _orNull(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

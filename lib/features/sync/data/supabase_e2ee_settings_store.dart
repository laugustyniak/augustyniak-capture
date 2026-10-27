import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/e2ee_settings_store.dart';

/// `public.user_e2ee_settings`, one row per `owner_id`, readable,
/// insertable by its owner only (RLS); there is no update or delete grant, so
/// the row is insert-once. An update would re-key the account and orphan every
/// envelope sealed under the first key.
class SupabaseE2eeSettingsStore implements E2eeSettingsStore {
  SupabaseE2eeSettingsStore(this._client);

  static const String table = 'user_e2ee_settings';

  /// Postgres `unique_violation`: the insert raced another device's set-up.
  static const String _uniqueViolation = '23505';

  final SupabaseClient _client;

  @override
  Future<E2eePublicParams?> read(String ownerId) async {
    final Map<String, dynamic>? row = await _client
        .from(table)
        .select()
        .eq('owner_id', ownerId)
        .maybeSingle();
    return row == null ? null : paramsFromRow(row);
  }

  @override
  Future<void> create(String ownerId, E2eePublicParams params) async {
    try {
      await _client.from(table).insert(rowFor(ownerId, params));
    } on PostgrestException catch (error) {
      if (error.code == _uniqueViolation) {
        throw const E2eeSettingsConflictException();
      }
      rethrow;
    }
  }

  /// Throws [FormatException] rather than returning null for a row missing
  /// a column: a row that exists but cannot be used must keep sync refused,
  /// not let a device set up a second key over it.
  static E2eePublicParams paramsFromRow(Map<String, dynamic> row) {
    final Object? salt = row['kdf_salt'];
    final Object? hash = row['key_check_hash'];
    final Object? iterations = row['kdf_iterations'];
    final Object? algorithm = row['kdf_algorithm'];
    if (salt is! String ||
        hash is! String ||
        iterations is! int ||
        algorithm is! String) {
      throw FormatException('malformed $table row', row);
    }
    return E2eePublicParams(
      saltBase64: salt,
      keyCheckHash: hash,
      iterations: iterations,
      algorithm: algorithm,
    );
  }

  static Map<String, Object?> rowFor(String ownerId, E2eePublicParams params) =>
      <String, Object?>{
        'owner_id': ownerId,
        'kdf_salt': params.saltBase64,
        'kdf_algorithm': params.algorithm,
        'key_check_hash': params.keyCheckHash,
        'kdf_iterations': params.iterations,
      };
}

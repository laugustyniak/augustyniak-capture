import 'package:augustyniak_capture/features/sync/data/supabase_e2ee_settings_store.dart';
import 'package:augustyniak_capture/features/sync/domain/e2ee_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const E2eePublicParams params = E2eePublicParams(
    saltBase64: 'c2FsdA==',
    keyCheckHash: 'kc1:abc',
    iterations: 600000,
  );

  test('a row carries exactly the four KDF columns and the owner', () {
    final Map<String, Object?> row = SupabaseE2eeSettingsStore.rowFor('u', params);
    expect(row, <String, Object?>{
      'owner_id': 'u',
      'kdf_salt': 'c2FsdA==',
      'kdf_algorithm': 'pbkdf2_sha256',
      'key_check_hash': 'kc1:abc',
      'kdf_iterations': 600000,
    });
    final E2eePublicParams back = SupabaseE2eeSettingsStore.paramsFromRow(row);
    expect(back.saltBase64, params.saltBase64);
    expect(back.keyCheckHash, params.keyCheckHash);
    expect(back.iterations, params.iterations);
    expect(back.algorithm, params.algorithm);
  });

  test('a row missing a column is malformed, not "no key"', () {
    // Returning null here would let a device set up a second key over the
    // first device's envelopes; the read has to fail instead.
    final Map<String, Object?> row = SupabaseE2eeSettingsStore.rowFor('u', params)
      ..remove('kdf_iterations');
    expect(() => SupabaseE2eeSettingsStore.paramsFromRow(row), throwsFormatException);
    row['kdf_iterations'] = '600000';
    expect(() => SupabaseE2eeSettingsStore.paramsFromRow(row), throwsFormatException);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
import '../domain/app_settings.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';

/// Persists settings in SQLite database while preserving AES-GCM token encryption
/// at rest via [TokenCipher] and master key in the OS keyring.
class SettingsRepository {
  SettingsRepository({TokenCipher? cipher, Database? db})
      : _cipher = cipher ?? const PlaintextTokenCipher(),
        _dbOverride = db;

  final TokenCipher _cipher;
  final Database? _dbOverride;

  bool get encryptsTokens => _cipher.encrypts;

  String? get tokenEncryptionIssue => _cipher.unavailableReason;

  /// Optional file override for legacy test compatibility
  Future<File?> settingsFile() async => null;

  Future<AppDatabase> _getDb() async {
    return AppDatabase.getInstance(overrideDb: _dbOverride);
  }

  Future<AppSettings?> load() async {
    await _cipher.ensureReady();

    final File? customFile = await settingsFile();
    if (customFile != null) {
      if (!await customFile.exists()) return null;
      final String raw = await customFile.readAsString();
      if (raw.trim().isEmpty) return null;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final AppSettings stored = AppSettings.fromJson(decoded);
      final AppSettings settings = await unsealTokens(stored);
      if (_cipher.encrypts && _hasPlaintextToken(stored)) {
        try {
          await save(settings);
        } catch (_) {}
      }
      return settings;
    }

    final AppDatabase db = await _getDb();
    await db.migrateFromLegacyJsonIfNeeded();

    final ResultSet results = db.rawDb.select('''
      SELECT value_json FROM settings WHERE key = 'app_settings';
    ''');

    if (results.isEmpty) {
      AppSettings settings = const AppSettings();
      try {
        final Directory docsDir = await getApplicationDocumentsDirectory();
        final File legacyFile = File(p.join(docsDir.path, 'recordings', 'settings.json'));
        if (await legacyFile.exists()) {
          final String raw = await legacyFile.readAsString();
          if (raw.trim().isNotEmpty) {
            final dynamic decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              settings = await unsealTokens(AppSettings.fromJson(decoded));
            }
          }
        }
      } catch (_) {}

      if (settings.tursoDbUrl == null || settings.r2Bucket == null) {
        settings = settings.copyWith(
          tursoDbUrl: settings.tursoDbUrl ??
              'libsql://augustyniak-capture-laugustyniak.aws-us-east-1.turso.io',
          tursoAuthToken: settings.tursoAuthToken ??
              'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3ODYxMDkwNDIsImlkIjoiMDE5ZmRjNjUtMTkwMS03N2JiLTk2NmMtYzQ4OGY0MmY4Y2Y5Iiwia2lkIjoiS05WbTBXMHhOZjdyd21pSXRrczdYMGdmYml3VGhGQ0RPbEtxemU4UUZmdyIsInJpZCI6IjE3MTJmZDJhLWVmY2MtNGI2MC1iZjQyLTVhMmEzNmYwYzkzYiJ9.4bvw9Cf9oMVSzDJSaZ9eq6bOTwbCXuYdast_FzKEddESgS3G3NCjjkSgJE7SRs17xtuTog42tJtrVRZ1Etl0Ag',
          tursoSyncEnabled: true,
          r2Endpoint: settings.r2Endpoint ??
              'https://e779027f883e48c2e7f31c5850408dba.r2.cloudflarestorage.com',
          r2Bucket: settings.r2Bucket ?? 'augustyniak-capture-media',
          r2AccessKeyId:
              settings.r2AccessKeyId ?? 'f7d5be45dff4ab4d90f1910219751723',
          r2SecretAccessKey: settings.r2SecretAccessKey ??
              '76e04917e25001440e2fb2ffb4143ad1b39624726eb42ac8074fb6f5e25f2a36',
          r2MediaSyncEnabled: true,
        );
      }
      try {
        await save(settings);
      } catch (_) {}
      return settings;
    }

    final String raw = results.single['value_json'] as String;
    if (raw.trim().isEmpty) return null;

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;

    final AppSettings stored = AppSettings.fromJson(decoded);
    AppSettings settings = await unsealTokens(stored);

    if (settings.tursoDbUrl == null || settings.r2Bucket == null) {
      settings = settings.copyWith(
        tursoDbUrl: settings.tursoDbUrl ??
            'libsql://augustyniak-capture-laugustyniak.aws-us-east-1.turso.io',
        tursoAuthToken: settings.tursoAuthToken ??
            'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3ODYxMDkwNDIsImlkIjoiMDE5ZmRjNjUtMTkwMS03N2JiLTk2NmMtYzQ4OGY0MmY4Y2Y5Iiwia2lkIjoiS05WbTBXMHhOZjdyd21pSXRrczdYMGdmYml3VGhGQ0RPbEtxemU4UUZmdyIsInJpZCI6IjE3MTJmZDJhLWVmY2MtNGI2MC1iZjQyLTVhMmEzNmYwYzkzYiJ9.4bvw9Cf9oMVSzDJSaZ9eq6bOTwbCXuYdast_FzKEddESgS3G3NCjjkSgJE7SRs17xtuTog42tJtrVRZ1Etl0Ag',
        tursoSyncEnabled: true,
        r2Endpoint: settings.r2Endpoint ??
            'https://e779027f883e48c2e7f31c5850408dba.r2.cloudflarestorage.com',
        r2Bucket: settings.r2Bucket ?? 'augustyniak-capture-media',
        r2AccessKeyId:
            settings.r2AccessKeyId ?? 'f7d5be45dff4ab4d90f1910219751723',
        r2SecretAccessKey: settings.r2SecretAccessKey ??
            '76e04917e25001440e2fb2ffb4143ad1b39624726eb42ac8074fb6f5e25f2a36',
        r2MediaSyncEnabled: true,
      );
      try {
        await save(settings);
      } catch (_) {}
    } else if (_cipher.encrypts && _hasPlaintextToken(stored)) {
      try {
        await save(settings);
      } catch (_) {}
    }

    return settings;
  }

  Future<void> save(AppSettings settings) async {
    await _cipher.ensureReady();
    final AppSettings sealed = await sealTokens(settings);

    final File? customFile = await settingsFile();
    if (customFile != null) {
      final String payload =
          const JsonEncoder.withIndent('  ').convert(sealed.toJson());
      final File temporary = File('${customFile.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(customFile.path);
      return;
    }

    final AppDatabase db = await _getDb();
    db.rawDb.execute('''
      INSERT OR REPLACE INTO settings (key, value_json) VALUES ('app_settings', ?);
    ''', <Object?>[jsonEncode(sealed.toJson())]);
  }

  Future<AppSettings> sealTokens(AppSettings settings) =>
      _mapTokens(settings, _cipher.seal);

  Future<AppSettings> unsealTokens(AppSettings settings) =>
      _mapTokens(settings, _cipher.unseal);

  Future<AppSettings> _mapTokens(
    AppSettings settings,
    Future<String> Function(String value) transform,
  ) async {
    bool changed = false;
    final List<ProviderProfile> profiles = <ProviderProfile>[];
    for (final ProviderProfile profile in settings.profiles) {
      final String? token = profile.bearerToken;
      if (token == null) {
        profiles.add(profile);
        continue;
      }
      final String value = await transform(token);
      if (value == token) {
        profiles.add(profile);
      } else {
        changed = true;
        profiles.add(profile.copyWith(bearerToken: value));
      }
    }

    String? tursoToken = settings.tursoAuthToken;
    if (tursoToken != null && tursoToken.isNotEmpty) {
      final String value = await transform(tursoToken);
      if (value != tursoToken) {
        changed = true;
        tursoToken = value;
      }
    }

    String? r2Secret = settings.r2SecretAccessKey;
    if (r2Secret != null && r2Secret.isNotEmpty) {
      final String value = await transform(r2Secret);
      if (value != r2Secret) {
        changed = true;
        r2Secret = value;
      }
    }

    return changed
        ? settings.copyWith(
            profiles: profiles,
            tursoAuthToken: tursoToken,
            r2SecretAccessKey: r2Secret,
          )
        : settings;
  }

  static bool _hasPlaintextToken(AppSettings settings) {
    if (settings.tursoAuthToken != null &&
        settings.tursoAuthToken!.isNotEmpty &&
        !TokenCipher.isSealed(settings.tursoAuthToken!)) {
      return true;
    }
    if (settings.r2SecretAccessKey != null &&
        settings.r2SecretAccessKey!.isNotEmpty &&
        !TokenCipher.isSealed(settings.r2SecretAccessKey!)) {
      return true;
    }
    return settings.profiles.any((ProviderProfile profile) =>
        profile.bearerToken != null &&
        !TokenCipher.isSealed(profile.bearerToken!));
  }
}

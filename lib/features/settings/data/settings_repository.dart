import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/owner_only_file.dart';
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

  /// Bring the cipher up, having first told it whether [raw] already contains
  /// sealed values.
  ///
  /// The order is the whole point and it is why `ensureReady` no longer runs at
  /// the top of [load]: the announcement has to land before the cipher decides
  /// whether a key store that answered "nothing here" is a first run or a
  /// failure. `ensureReady` memoises, so the later calls are free.
  ///
  /// The test is against the raw payload rather than the parsed fields on
  /// purpose — a secret added to [AppSettings] later is covered the day it is
  /// persisted, instead of the day someone remembers to extend a list here.
  Future<void> _prepareCipher(String raw) async {
    if (raw.contains(TokenCipher.sealedPrefix)) _cipher.expectExistingKey();
    await _cipher.ensureReady();
  }

  Future<AppSettings?> load() async {
    final File? customFile = await settingsFile();
    if (customFile != null) {
      if (!await customFile.exists()) {
        await _cipher.ensureReady();
        return null;
      }
      final String raw = await customFile.readAsString();
      await _prepareCipher(raw);
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
        final File legacyFile = File(
          p.join(docsDir.path, 'recordings', 'settings.json'),
        );
        if (await legacyFile.exists()) {
          final String raw = await legacyFile.readAsString();
          if (raw.trim().isNotEmpty) {
            await _prepareCipher(raw);
            final dynamic decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              settings = await unsealTokens(AppSettings.fromJson(decoded));
            }
          }
        }
      } catch (_) {}

      try {
        await save(settings);
      } catch (_) {}
      return settings;
    }

    final String raw = results.single['value_json'] as String;
    await _prepareCipher(raw);
    if (raw.trim().isEmpty) return null;

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;

    final AppSettings stored = AppSettings.fromJson(decoded);
    final AppSettings settings = await unsealTokens(stored);

    // A token that will not open is left exactly as it is: only a plaintext
    // one is rewritten, sealed.
    if (_cipher.encrypts && _hasPlaintextToken(stored)) {
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
      final String payload = const JsonEncoder.withIndent(
        '  ',
      ).convert(sealed.toJson());
      final File temporary = File('${customFile.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      // Tightened before the rename, so the tokens are never momentarily
      // world-readable at their final path — the same ordering, and the same
      // reason, as `FileMasterKeyStore.write`.
      await restrictToOwner(temporary.path);
      await temporary.rename(customFile.path);
      return;
    }

    final AppDatabase db = await _getDb();
    db.rawDb.execute(
      '''
      INSERT OR REPLACE INTO settings (key, value_json) VALUES ('app_settings', ?);
    ''',
      <Object?>[jsonEncode(sealed.toJson())],
    );
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

    String? commandToken = settings.commandToken;
    if (commandToken != null && commandToken.isNotEmpty) {
      final String value = await transform(commandToken);
      if (value != commandToken) {
        changed = true;
        commandToken = value;
      }
    }

    return changed
        ? settings.copyWith(
            profiles: profiles,
            commandToken: commandToken,
          )
        : settings;
  }

  static bool _hasPlaintextToken(AppSettings settings) {
    if (settings.commandToken != null &&
        settings.commandToken!.isNotEmpty &&
        !TokenCipher.isSealed(settings.commandToken!)) {
      return true;
    }
    return settings.profiles.any(
      (ProviderProfile profile) =>
          profile.bearerToken != null &&
          !TokenCipher.isSealed(profile.bearerToken!),
    );
  }
}

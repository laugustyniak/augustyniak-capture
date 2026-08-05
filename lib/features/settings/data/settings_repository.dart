import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/app_settings.dart';
import '../domain/provider_profile.dart';
import '../domain/token_cipher.dart';

/// Persists `settings.json` next to `recordings.json`, using the same atomic
/// write (`.tmp` then `rename`) so a crash mid-write cannot truncate settings.
///
/// Bearer tokens cross this boundary through [TokenCipher]: sealed on the way
/// to disk, unsealed on the way back, so the in-memory [AppSettings] always
/// holds what an `Authorization` header needs. The default cipher is the
/// plaintext identity — existing tests and a keyring-less runtime behave
/// exactly as before.
class SettingsRepository {
  SettingsRepository({TokenCipher? cipher})
      : _cipher = cipher ?? const PlaintextTokenCipher();

  final TokenCipher _cipher;

  /// Whether tokens written by [save] are actually encrypted — drives the
  /// Models/Config tab copy.
  bool get encryptsTokens => _cipher.encrypts;

  /// Why they are not, when they are not. Null while encryption is on, and
  /// null for the plaintext identity cipher, which is a choice rather than a
  /// failure. See [TokenCipher.unavailableReason].
  String? get tokenEncryptionIssue => _cipher.unavailableReason;

  Future<Directory> _directory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> settingsFile() async {
    final Directory directory = await _directory();
    return File(p.join(directory.path, 'settings.json'));
  }

  Future<AppSettings?> load() async {
    await _cipher.ensureReady();

    final File file = await settingsFile();
    if (!await file.exists()) {
      return null;
    }

    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return null;
    }

    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final AppSettings stored = AppSettings.fromJson(decoded);
    final AppSettings settings = await unsealTokens(stored);

    // One-time migration: a file holding any plaintext token is rewritten
    // sealed as soon as a working cipher sees it. With no cipher the file is
    // deliberately left untouched and the migration retries next launch.
    if (_cipher.encrypts && _hasPlaintextToken(stored)) {
      // Best-effort: the migration write can fail (disk full, read-only
      // dir) and must never cost the session its already-parsed settings.
      // Swallow it here and retry on a later launch, exactly like the
      // keyring-unavailable path.
      try {
        await save(settings);
      } catch (_) {
        // Migration retries next launch; the returned settings are still
        // the correctly-unsealed in-memory values from this load.
      }
    }
    return settings;
  }

  Future<void> save(AppSettings settings) async {
    await _cipher.ensureReady();
    final AppSettings sealed = await sealTokens(settings);

    final File file = await settingsFile();
    final String payload =
        const JsonEncoder.withIndent('  ').convert(sealed.toJson());

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }

  /// Seal every profile token for disk. Public (rather than folded into
  /// [save]) so the transform is testable without file IO. An already-sealed
  /// value — an unrecoverable blob carried in memory — passes through
  /// verbatim: re-sealing it would wrap ciphertext in ciphertext and lose the
  /// original token forever.
  Future<AppSettings> sealTokens(AppSettings settings) =>
      _mapTokens(settings, _cipher.seal);

  /// Unseal every profile token after parse. A blob the cipher cannot decrypt
  /// comes back unchanged — see [TokenCipher.unseal].
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
    return changed ? settings.copyWith(profiles: profiles) : settings;
  }

  static bool _hasPlaintextToken(AppSettings settings) =>
      settings.profiles.any((ProviderProfile profile) =>
          profile.bearerToken != null &&
          !TokenCipher.isSealed(profile.bearerToken!));
}

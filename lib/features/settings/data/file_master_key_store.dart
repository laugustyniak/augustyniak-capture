import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'aes_gcm_token_cipher.dart';

/// [MasterKeyStore] backed by an owner-only file beside the database.
///
/// **It exists because the OS keyring identifies this app by its code
/// signature, and this app has no stable one.** Builds are ad-hoc signed
/// (`CODE_SIGN_IDENTITY = "-"`, see CLAUDE.md), so every rebuild produces a new
/// `cdhash`, and macOS's classic login keychain stores an ACL naming the exact
/// hashes it trusts. A freshly built binary is therefore a stranger to the
/// entry it wrote yesterday: the read is refused, [AesGcmTokenCipher] swallows
/// it as designed, `encrypts` goes false — and every already-sealed token turns
/// into an `enc:v1:` blob that `ProviderProfile.usableBearerToken` filters out,
/// so requests go out with no `Authorization` header and the provider answers
/// 401. Nothing on screen connects the two. The keychain ACL on this machine
/// had **thirteen** entries by the time it was diagnosed, one per build the
/// user had clicked "Always Allow" for, and the fourteenth (a build from a git
/// worktree) was what broke it.
///
/// A file cannot refuse the process that owns it, so this is deterministic
/// where the keyring is not. The trade is real and deliberate: the key now sits
/// next to the ciphertext it opens, which stops protecting against someone who
/// can read the whole support directory. What it still protects against is what
/// the encryption was actually for — a settings export, a synced backup, or a
/// pasted config leaking provider keys in the clear. Restoring the stronger
/// property needs a Developer ID signature, which lets a keychain ACL name the
/// app by Team ID instead of by hash; revisit this then.
///
/// [migrateFrom] is what makes the switch non-destructive: on first run the
/// key is **adopted** from the previous store rather than regenerated, so
/// tokens sealed under the keyring's key still open. A previous store that
/// refuses is not an error here — that refusal is the very condition this
/// class was written for.
class FileMasterKeyStore implements MasterKeyStore {
  FileMasterKeyStore({
    Future<Directory> Function()? directory,
    MasterKeyStore? migrateFrom,
  })  : _directory = directory ?? getApplicationSupportDirectory,
        _migrateFrom = migrateFrom;

  static const String fileName = 'token_master_key';

  final Future<Directory> Function() _directory;
  final MasterKeyStore? _migrateFrom;

  @override
  Future<String?> read() async {
    try {
      final File file = await _file();
      if (await file.exists()) {
        final String raw = (await file.readAsString()).trim();
        // A blank file reads as absent on purpose. Answering '' would decode
        // to a zero-length key, which [AesGcmTokenCipher] rejects as "an entry
        // this app did not write" — wedging encryption off with no way back,
        // where absent simply generates a fresh key.
        if (raw.isNotEmpty) return raw;
      }
    } catch (_) {
      // Unreadable file: fall through to the previous store, then to null.
      // Never throw — the cipher's contract is that a missing key degrades to
      // plaintext rather than failing a capture.
    }
    return _adopt();
  }

  @override
  Future<void> write(String value) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    // Tighten the mode *before* the rename, so the key is never momentarily
    // world-readable at its final path.
    await _restrictToOwner(temporary.path);
    await temporary.rename(file.path);
  }

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  /// Take over the key the previous store holds, once, and persist it here.
  Future<String?> _adopt() async {
    final MasterKeyStore? previous = _migrateFrom;
    if (previous == null) return null;
    String? inherited;
    try {
      inherited = await previous.read();
    } catch (_) {
      return null;
    }
    if (inherited == null || inherited.trim().isEmpty) return null;
    try {
      await write(inherited);
    } catch (_) {
      // Adoption failed to persist. Still hand the key back: this session
      // decrypts correctly, and the next launch retries the same adoption.
    }
    return inherited;
  }

  static Future<void> _restrictToOwner(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['600', path]);
    } catch (_) {
      // No chmod on this box. The key is still written — encryption working
      // at a laxer mode beats no encryption at all.
    }
  }
}

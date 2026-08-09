import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'aes_gcm_token_cipher.dart';

/// [MasterKeyStore] backed by an owner-only file beside the database.
///
/// **No longer the primary store — it is the copy the keyring migrates away
/// from,** wired as `MigratingMasterKeyStore.fallback` and deleted by
/// [delete] once the keyring hands the same key back. Left in place because
/// deleting the class would strand every install that still keeps its key here.
///
/// It existed because macOS's classic login keychain stores an ACL naming the
/// exact code signatures it trusts, and builds were ad-hoc signed — a new
/// `cdhash` every rebuild, so a freshly built binary was a stranger to the
/// entry it wrote yesterday. The read was refused, [AesGcmTokenCipher] swallowed
/// it as designed, `encrypts` went false, and every already-sealed token became
/// an `enc:v1:` blob that `ProviderProfile.usableBearerToken` filters out: the
/// requests went out with no `Authorization` header and providers answered 401,
/// with nothing on screen connecting the two. The ACL held **thirteen** entries
/// by the time it was diagnosed, one per build someone had clicked "Always
/// Allow" for, and the fourteenth — a build from a git worktree — broke it.
///
/// That cause is gone: `LOCAL_SIGN_IDENTITY` (see CLAUDE.md) gives the app a
/// designated requirement bound to a certificate rather than to a binary hash,
/// so one grant covers every future build and every worktree. With the keyring
/// dependable again, keeping the key beside the ciphertext it opens only costs
/// the protection encryption is for — a copied support directory yields both
/// halves at once — so the key moved back and this file is retired on sight.
///
/// [migrateFrom] belongs to the older direction of travel (file adopting from
/// keyring) and is kept for installs mid-migration; the current wiring passes
/// nothing, because `MigratingMasterKeyStore` owns the handover now.
class FileMasterKeyStore implements MasterKeyStore {
  FileMasterKeyStore({
    Future<Directory> Function()? directory,
    MasterKeyStore? migrateFrom,
  }) : _directory = directory ?? getApplicationSupportDirectory,
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

  /// Retire this copy of the key, once another store has demonstrably taken it
  /// over — see `MigratingMasterKeyStore`, which is the only caller and which
  /// reads the key back out of the new home before getting here.
  ///
  /// Deleting is the whole point of moving the key rather than copying it: a
  /// second copy beside the database would keep the weaker of the two
  /// protections in force. An absent file is success, not an error — the
  /// handover is attempted on every launch and this runs again afterwards.
  Future<void> delete() async {
    try {
      final File file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A key that cannot be deleted is untidy, never fatal: the live one is
      // already in the primary store.
    }
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

import 'dart:io';

/// Restrict [path] to `rw-------`, best-effort.
///
/// **Which files this is for:** the ones that hold a secret at rest — the token
/// master key, the SQLite database whose `settings` row carries provider
/// bearer tokens plus the Turso and R2 credentials, and the legacy
/// `settings.json` beside it. Those values are sealed while the key store
/// works and sit **in the clear when it does not**, which is a documented,
/// reachable state (a Linux box with no Secret Service; a macOS build the
/// keychain refuses). A fallback that hands the tokens to a `0644` file hands
/// them to every account on the machine, and to anything that later copies the
/// support directory.
///
/// `dart:io` exposes no `chmod`, so this shells out exactly as
/// `FileMasterKeyStore` has always done. It is best-effort for the same reason
/// that call was: a platform without `chmod` still gets the file written, and
/// encryption at a laxer mode beats refusing to save. A Windows path is a
/// no-op — the mode bits mean nothing there and the ACL is a different
/// question.
Future<void> restrictToOwner(String path) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', <String>['600', path]);
  } catch (_) {
    // No chmod on this box, or the file is gone. Never fatal: the caller is
    // saving a file, and a permission it could not tighten must not cost the
    // save itself.
  }
}

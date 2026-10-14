import 'dart:io';

import '../../features/logs/domain/log_event.dart';

/// Restrict [path] to `rw-------`, best-effort.
///
/// **Which files this is for:** the ones that hold a secret at rest — the token
/// master key, the SQLite database whose `settings` row carries provider
/// bearer tokens and the Command token, and the legacy
/// `settings.json` beside it. Those values are sealed while the key store
/// works and sit **in the clear when it does not**, which is a documented,
/// reachable state (a Linux box with no Secret Service; a macOS build the
/// keychain refuses). A fallback that hands the tokens to a `0644` file hands
/// them to every account on the machine, and to anything that later copies the
/// support directory.
///
/// It is also for a file the app writes **outside its own directories** — the
/// backup archive the user chose a location for, a note the markdown mirror
/// drops into a vault — because [restrictDirectoryToOwner] cannot reach those.
///
/// `dart:io` exposes no `chmod`, so this shells out exactly as
/// `FileMasterKeyStore` has always done. It is best-effort for the same reason
/// that call was: a platform without `chmod` still gets the file written, and
/// encryption at a laxer mode beats refusing to save. A Windows path is a
/// no-op — the mode bits mean nothing there and the ACL is a different
/// question.
Future<void> restrictToOwner(String path) => _chmod('600', path);

/// Restrict the directory at [path] to `rwx------`, best-effort.
///
/// One call covers every file inside, present and future, without a `chmod`
/// per write — and without the window a per-file call leaves between the
/// write landing at the umask's mode and the tightening. The recordings
/// directory (the index, every source file, the posters and the `.jsonl`
/// logs) and the support directory (the database, the key file) are the two
/// callers (#301). Same best-effort contract as [restrictToOwner].
Future<void> restrictDirectoryToOwner(String path) => _chmod('700', path);

/// The first `chmod` that failed this session, or null.
///
/// Reported once, the way `TokenCipher.unavailableReason` is: a failure here
/// means the tokens, the recordings or both are readable by every account on
/// the machine, and a silent best-effort is a decision the user never got to
/// see. Later failures are not recorded; one line is the whole message.
String? get ownerOnlyIssue => _issue;
String? _issue;

LogSink _log = const NoopLogSink();

/// Where the once-only failure line goes, besides [ownerOnlyIssue]. Set at
/// wiring; a failure before that is still kept in [ownerOnlyIssue].
void reportOwnerOnlyFailuresTo(LogSink sink) => _log = sink;

/// Test seam, named like `AppDatabase.resetForTesting`: pure-Dart, so no
/// `package:flutter` annotation here.
void resetOwnerOnlyReportingForTesting() {
  _issue = null;
  _log = const NoopLogSink();
}

Future<void> _chmod(String mode, String path) async {
  if (Platform.isWindows) return;
  // The caller may restrict a path it is about to write, or one that may never
  // have existed; neither is a failure worth a line.
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return;
  String? failure;
  try {
    final ProcessResult result = await Process.run('chmod', <String>[
      mode,
      path,
    ]);
    if (result.exitCode != 0) {
      failure = (result.stderr as String).trim();
      if (failure.isEmpty) failure = 'chmod exited ${result.exitCode}';
    }
  } catch (error) {
    // No chmod on this box. Never fatal: the caller is saving a file, and a
    // permission it could not tighten must not cost the save itself.
    failure = '$error';
  }
  if (failure == null || _issue != null) return;
  _issue = 'Could not restrict $path to the owner (chmod $mode): $failure';
  _log.log(_issue!, level: LogLevel.warn);
}

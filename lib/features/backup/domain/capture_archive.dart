import 'dart:io';

/// What an export run wrote.
class BackupSummary {
  const BackupSummary({
    required this.captures,
    required this.files,
    required this.bytes,
    required this.destination,
  });

  /// Rows in the exported index. Zero is a legitimate answer on a fresh
  /// install and is reported rather than treated as a failure.
  final int captures;

  /// Every member of the archive, index files included.
  final int files;

  /// Size of the archive on disk, so the user can tell a real backup from an
  /// empty one without opening it.
  final int bytes;

  /// Where it landed, verbatim, for the Config tab to print.
  final String destination;
}

/// What an import run found.
///
/// **Four numbers rather than one**, because "restored 0 captures" has three
/// causes that need different reactions: the archive was empty, everything in
/// it was already here, or its rows could not be read. One count would report
/// a successful no-op and a corrupt archive identically.
class RestoreSummary {
  const RestoreSummary({
    required this.added,
    required this.alreadyPresent,
    required this.unreadable,
    required this.filesRestored,
    this.matchedByIdAlone = 0,
  });

  /// Rows that were not in the local index and now are.
  final int added;

  /// Rows whose id already existed locally. Left exactly as they were — see
  /// [CaptureArchive.importFrom] for why the incoming copy never wins.
  final int alreadyPresent;

  /// Rows that could not be parsed or safely paired with a source artifact.
  /// Skipped individually, so one bad capture never costs the rest.
  final int unreadable;

  /// Immutable source artifacts copied in. Derived posters are regenerated.
  final int filesRestored;

  /// How many of [alreadyPresent] were recognised **only** because the archive
  /// and the local library share an id — the archived row carried no
  /// `contentHash` to compare.
  ///
  /// Reported rather than folded into [alreadyPresent], because the two are
  /// different promises. A hash match means *these are the same bytes*; an id
  /// match means *this archive was taken from this library*, which says nothing
  /// about a copy that travelled through another device. An archive written
  /// before content hashing existed restores looking perfectly deduplicated
  /// while having compared nothing, and silently degrading to the weaker rule
  /// is exactly what the feature was asked not to do.
  final int matchedByIdAlone;
}

/// A portable copy of everything the queue is made of.
///
/// **Why this exists at all.** On desktop the recordings directory is an
/// ordinary folder and a backup is the user's own business. On Android and iOS
/// it lives *inside the app container*, which a reinstall — a new signature, a
/// changed `applicationId`, `flutter run` after an uninstall — deletes outright.
/// Every capture, and more importantly every transcript, goes with it. That was
/// documented in this repo as loss no code here could prevent; this is the code.
///
/// **A zip of plain files, for the same reason `inbox.md` is a file.** It needs
/// no server and no account, so it does not trade away the property the whole
/// app is built on, and it opens in every unzip tool the user already has. A
/// backup nobody can read without this app is a second way to lose the data.
///
/// **Credentials are deliberately not in it.** `settings.json` shares the
/// recordings directory but carries provider bearer tokens, sealed under a
/// master key that lives in the OS keyring and does not travel. Copying them
/// would export secrets that are useless at the destination — the worst of both
/// halves. Profiles are retyped after a restore; captures cannot be.
abstract interface class CaptureArchive {
  /// Stream the archive to [destination]. Throws on failure — a backup that
  /// half-wrote and reported success is worse than one that failed loudly.
  Future<BackupSummary> exportTo(File destination);

  /// Merge [source] into the local store.
  ///
  /// **Additive, never destructive, and that is the whole contract.** The
  /// index survives a bad read is this app's second durability rule, and a
  /// restore that rewrote `recordings.json` from an archive is precisely the
  /// shape that once destroyed it. So:
  ///
  /// * a row whose source hash exists in the pre-import local library is left
  ///   **exactly** as it is, and the incoming copy is discarded. Legacy rows
  ///   without a hash fall back to id. The local one may have been edited,
  ///   enriched and routed since the archive was taken; the archived one is by
  ///   definition older. Counting it as [RestoreSummary.alreadyPresent] says so.
  /// * a source file already on disk is never overwritten.
  /// * files are written **before** the rows that point at them. A row with no
  ///   file is a broken capture with nothing to recover; a file with no row is
  ///   an orphan, and `recoverOrphans()` already walks those back into the
  ///   queue. Only one of those two failure modes is survivable, so the order
  ///   is chosen to fail into it.
  ///
  /// Absolute paths inside the archive are rewritten against the local
  /// recordings directory: a container path from another install, or another
  /// platform, points nowhere here.
  Future<RestoreSummary> importFrom(File source);
}

/// The default for hosts with nothing to archive — tests, and any shell that
/// has not wired a real one. Same shape as `DisabledCaptureRouter`.
class DisabledCaptureArchive implements CaptureArchive {
  const DisabledCaptureArchive();

  @override
  Future<BackupSummary> exportTo(File destination) async {
    throw const CaptureArchiveUnavailableException();
  }

  @override
  Future<RestoreSummary> importFrom(File source) async {
    throw const CaptureArchiveUnavailableException();
  }
}

class CaptureArchiveUnavailableException implements Exception {
  const CaptureArchiveUnavailableException();

  @override
  String toString() => 'Backup is not available on this platform.';
}

/// An archive that is not one, or is one this build cannot read.
class ArchiveUnreadableException implements Exception {
  const ArchiveUnreadableException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'Not a readable capture archive ($path): $reason';
}

/// An export too large for the platform path that has to buffer it.
///
/// Android and iOS hand the *bytes* to the storage-access framework rather than
/// a path to write, so there is no streaming option there. Saying so is the
/// only honest outcome above the ceiling: the alternative is an OOM kill with
/// nothing on screen explaining it.
class ArchiveTooLargeException implements Exception {
  const ArchiveTooLargeException(this.bytes, this.limitBytes);

  final int bytes;
  final int limitBytes;

  @override
  String toString() =>
      'The archive is ${(bytes / (1024 * 1024)).round()} MB and this platform '
      'can save at most ${(limitBytes / (1024 * 1024)).round()} MB in one go. '
      'Export to a computer instead.';
}

/// Where an exported archive goes, and where an imported one comes from.
///
/// A seam for the same reason `DirectoryPicker` and `MediaPicker` are: the real
/// implementation opens a system dialog, and the suites must be able to
/// exercise the whole export path without one. It also absorbs a genuine
/// platform split — a desktop save dialog hands back a path to write, while
/// Android's storage-access framework takes the bytes and writes them itself —
/// so nothing above this interface has to know which happened.
abstract interface class ArchiveLocationPicker {
  /// Deliver [staged] to wherever the user chooses. Returns a human-readable
  /// description of where it landed, or null if they cancelled.
  ///
  /// Takes an already-written file rather than bytes so the common desktop case
  /// never holds a multi-gigabyte archive in memory.
  Future<String?> deliver(File staged, String suggestedName);

  /// Pick an archive to import, or null if the user cancelled.
  Future<File?> chooseArchive();
}

/// Cancels everything. The Config tab renders the section disabled rather than
/// offering buttons that open nothing.
class DisabledArchiveLocationPicker implements ArchiveLocationPicker {
  const DisabledArchiveLocationPicker();

  @override
  Future<String?> deliver(File staged, String suggestedName) async => null;

  @override
  Future<File?> chooseArchive() async => null;
}

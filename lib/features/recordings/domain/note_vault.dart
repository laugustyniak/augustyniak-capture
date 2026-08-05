import 'capture_category.dart';
import 'capture_type.dart';

/// Everything a vault needs to write one capture down as a markdown note.
///
/// Flattened off `Recording` for the same reason [RoutedCapture] is: this layer
/// must be testable without building an item, and a destination must never have
/// to reimplement the card's title cascade or reach back into the projects
/// controller for a name.
class VaultNote {
  const VaultNote({
    required this.id,
    required this.title,
    required this.body,
    required this.capturedAt,
    required this.type,
    this.summary,
    this.category,
    this.tags = const <String>[],
    this.projectId,
    this.durationMs = 0,
    this.sourcePath,
  });

  /// The capture id. It is what identifies the note's file on disk forever
  /// after — see [NoteVault.mirror] for why the *name* cannot carry that job.
  final String id;

  /// Already resolved by the caller: the item's own title, or the card's
  /// fallback name. A vault never writes a uuid as a heading.
  final String title;

  /// The processor output — transcript, OCR text, or the note body.
  final String body;

  final DateTime capturedAt;
  final CaptureType type;
  final String? summary;
  final CaptureCategory? category;
  final List<String> tags;

  /// Resolved to a name by the vault, exactly as `ProjectInboxRouter` resolves
  /// a destination: the projects list is owned elsewhere and changes under both
  /// of them, so the id travels and the lookup happens at write time.
  final String? projectId;

  final int durationMs;

  /// Absolute path of the source artifact, when there is one worth attaching.
  /// Null leaves the note text-only.
  final String? sourcePath;
}

/// What happened to one note, so the caller can report a skip rather than
/// claiming a write that never landed.
enum VaultOutcome {
  /// A note that had no file in the vault before.
  created,

  /// An existing note of ours, rewritten because a mirrored field changed.
  updated,

  /// Already identical on disk — no write, and deliberately so: rewriting an
  /// unchanged file would bump its mtime and move it to the top of every
  /// "recently modified" list in the reader's application for nothing.
  unchanged,

  /// The file exists but is no longer the one we wrote. Left alone.
  foreign,
}

class VaultWrite {
  const VaultWrite({required this.outcome, this.path});

  final VaultOutcome outcome;

  /// Absolute path of the note. Null only when nothing was located or written.
  final String? path;
}

/// What a sweep over the whole queue did, for the Config tab's report.
///
/// Counted rather than listed: the interesting numbers are how many notes are
/// now in the vault and how many were left alone because somebody had edited
/// them — a list of paths would be a second file browser nobody asked for.
class VaultMirrorSummary {
  const VaultMirrorSummary({
    this.created = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.foreign = 0,
    this.failed = 0,
  });

  final int created;
  final int updated;
  final int unchanged;

  /// Notes the reader has since edited. Reported rather than swallowed: this is
  /// the one outcome that looks like a failure to mirror and is in fact the
  /// mirror doing its job.
  final int foreign;

  final int failed;

  int get total => created + updated + unchanged + foreign + failed;

  VaultMirrorSummary plus(VaultOutcome outcome) => VaultMirrorSummary(
    created: created + (outcome == VaultOutcome.created ? 1 : 0),
    updated: updated + (outcome == VaultOutcome.updated ? 1 : 0),
    unchanged: unchanged + (outcome == VaultOutcome.unchanged ? 1 : 0),
    foreign: foreign + (outcome == VaultOutcome.foreign ? 1 : 0),
    failed: failed,
  );

  VaultMirrorSummary withFailure() => VaultMirrorSummary(
    created: created,
    updated: updated,
    unchanged: unchanged,
    foreign: foreign,
    failed: failed + 1,
  );
}

/// Mirrors captures into a second location as markdown files.
///
/// A seam under the same rules as `ClipboardSink` and `CaptureRouter`: the real
/// implementation writes to a directory the user owns, so the pure-Dart suites
/// take the disabled default and never touch one.
///
/// **This is a mirror, not a route, and the distinction is the whole design.**
/// `CaptureRouter` delivers a capture once: the write is append-only, it closes
/// the item, and routing twice records two deliveries because two really
/// happened. A vault holds *the same note over time* — enrichment names it
/// minutes after it was created, and a transcript can be corrected a week later
/// — so the same capture must be able to reach the same file again. Folding the
/// two together would mean either an inbox that accumulates duplicates of one
/// thought, or a mirror that could never record a second delivery honestly.
abstract interface class NoteVault {
  /// Whether a destination is configured at all. Synchronous, like
  /// `CaptureRouter.canRoute`: the Config tab gates its controls on it during
  /// `build`, and it is configuration rather than state.
  bool get isConfigured;

  /// Write [note] to the vault, or report why it was left alone.
  ///
  /// Throws on a genuine failure (missing directory, unwritable disk). The
  /// caller treats this as best-effort under the `ClipboardSink` contract — a
  /// vault that cannot be written costs a copy, never the capture.
  Future<VaultWrite> mirror(VaultNote note);
}

/// Layout constants, in the domain rather than beside the implementation
/// because `AppSettings` carries the folder the user chose and needs the same
/// default. Two copies of the string would drift the first time one changed,
/// and the symptom would be a second directory quietly appearing in the vault.
class VaultDefaults {
  /// Notes land in a subfolder rather than the vault root: a vault is somebody
  /// else's filing system, and emptying a hundred machine-written files into
  /// the top of it is not a merge.
  static const String folder = 'Capture';

  /// Obsidian's own convention for where embedded media lives.
  static const String attachments = 'attachments';
}

/// The default: no second location, so nothing is copied anywhere.
class DisabledNoteVault implements NoteVault {
  const DisabledNoteVault();

  @override
  bool get isConfigured => false;

  @override
  Future<VaultWrite> mirror(VaultNote note) async {
    throw const VaultNotConfiguredException();
  }
}

/// Thrown when a mirror is asked for with no vault directory set. Logged at
/// `warn` rather than `error` by the controller, exactly like
/// `EnrichmentNotConfiguredException`: on an install that never configured one
/// it is the expected answer, not a fault.
class VaultNotConfiguredException implements Exception {
  const VaultNotConfiguredException();

  @override
  String toString() =>
      'No vault directory configured — set one in Config to mirror notes.';
}

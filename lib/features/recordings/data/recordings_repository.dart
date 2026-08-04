import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/capture_type.dart';
// Prefixed so the class-level `extensionFor` below can delegate to the domain
// policy instead of recursing into itself.
import '../domain/capture_type.dart' as policy;
import '../domain/recording.dart';

/// Thrown by [RecordingsRepository.loadAll] when the index exists but cannot be
/// understood at all — unreadable bytes, or a payload that is not a JSON list.
///
/// This is deliberately *not* the same outcome as an absent index. An absent
/// index means "fresh install, the queue is legitimately empty"; an unreadable
/// one means "there is history here and I cannot see it". Collapsing the two is
/// what turns a read problem into permanent data loss, because the caller then
/// persists its empty in-memory list over the file it failed to read.
///
/// The unreadable bytes are never destroyed: [RecordingsRepository.loadAll]
/// copies them aside as `recordings.corrupt-<timestamp>.json` before throwing.
class IndexUnreadableException implements Exception {
  const IndexUnreadableException(this.path, this.cause, {this.backupPath});

  /// The index that could not be read.
  final String path;

  /// Whatever `readAsString`/`jsonDecode` actually threw.
  final Object cause;

  /// Where the unreadable bytes were preserved, or null if even that failed.
  final String? backupPath;

  @override
  String toString() => 'Recordings index at $path is unreadable: $cause'
      '${backupPath == null ? '' : ' (kept a copy at $backupPath)'}';
}

class RecordingsRepository {
  /// Storage-policy surface: which extension an item of [type] is stored under.
  /// Delegates to the single definition in `capture_type.dart`, and names the
  /// parameter after the `Recording.sourceMimeType` field it is fed from.
  static String extensionFor(CaptureType type, {String? sourceMimeType}) =>
      policy.extensionFor(type, mimeType: sourceMimeType);

  /// How many rows the last successful [loadAll] or [saveAll] saw.
  ///
  /// The only reason this class holds state: it is what lets [saveAll] notice
  /// that an index is about to *shrink*. There is no delete in this app, so a
  /// shrinking index is by definition an anomaly, and it is the exact shape of
  /// the failure this file is hardened against. Null until the first load or
  /// save, so a repository that has never seen the index never guesses.
  int? _knownCount;

  Future<Directory> recordingsDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(p.join(appDirectory.path, 'recordings'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Path for an item's source artifact: `<id>.<extension>` in the recordings
  /// directory. The file is not created here — callers write it and verify a
  /// non-zero length before the item is ever indexed.
  Future<File> createSourceFile(String id, String extension) async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, '$id.$extension'));
  }

  /// Mic-capture path, unchanged.
  Future<File> createAudioFile(String id) => createSourceFile(id, 'm4a');

  /// Read the index.
  ///
  /// Three outcomes, and keeping them apart is the whole point:
  /// * **absent or blank** → empty list. A fresh install; writing over it later
  ///   is correct.
  /// * **a JSON list with some unparseable rows** → the rows that *did* parse,
  ///   with the original bytes copied aside first. One row holding a null `id`
  ///   must not cost the other ninety-nine, and the copy means the dropped row
  ///   is recoverable by hand.
  /// * **anything else** → [IndexUnreadableException], after preserving the
  ///   bytes. The caller must refuse to write until this is resolved.
  Future<List<Recording>> loadAll() async {
    final File index = await _indexFile();
    if (!await index.exists()) {
      _knownCount = 0;
      return <Recording>[];
    }

    final String raw;
    final dynamic decoded;
    try {
      raw = await index.readAsString();
      if (raw.trim().isEmpty) {
        _knownCount = 0;
        return <Recording>[];
      }
      decoded = jsonDecode(raw);
    } catch (exception) {
      throw IndexUnreadableException(
        index.path,
        exception,
        backupPath: await _preserve(index, 'corrupt'),
      );
    }

    if (decoded is! List<dynamic>) {
      throw IndexUnreadableException(
        index.path,
        'expected a JSON list, got ${decoded.runtimeType}',
        backupPath: await _preserve(index, 'corrupt'),
      );
    }

    final List<Recording> recordings = <Recording>[];
    bool droppedARow = false;
    for (final dynamic item in decoded) {
      try {
        recordings.add(Recording.fromJson(item as Map<String, dynamic>));
      } catch (_) {
        // Per-row degradation, the same rule `Recording.fromJson` already
        // applies per *field*: a malformed row is skipped rather than taking
        // every other recording down with it.
        droppedARow = true;
      }
    }
    if (droppedARow) {
      // The next save would write the surviving rows over the file the dropped
      // one still lives in, so preserve it now while it is still on disk.
      await _preserve(index, 'partial');
    }

    recordings.sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
    _knownCount = recordings.length;
    return recordings;
  }

  Future<void> saveAll(List<Recording> recordings) async {
    final File index = await _indexFile();

    // No path in this app deletes an item, so an index that is about to lose
    // rows is an anomaly rather than a user action — and it is precisely the
    // moment history would be destroyed. Cheap because it never fires in normal
    // use: one copy at the exact instant something is going wrong.
    final int? previous = _knownCount;
    if (previous != null && recordings.length < previous && await index.exists()) {
      await _preserve(index, 'shrank');
    }

    final String payload = const JsonEncoder.withIndent('  ')
        .convert(recordings.map((Recording item) => item.toJson()).toList());

    final File temporary = File('${index.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(index.path);
    _knownCount = recordings.length;
  }

  /// Source artifacts sitting in the recordings directory with no row in
  /// [indexed] — the physical remains of a lost index.
  ///
  /// Returns them as fresh `saved` items so they surface under the queue's RAW
  /// filter. `saved` and not `pendingTranscription` on purpose: re-adopting a
  /// hundred orphans must not silently spend a hundred transcription calls, so
  /// the user re-runs the ones they want via retry.
  ///
  /// What is recoverable is the artifact, not the derived text — a re-adopted
  /// item has no transcript, title or category, because those only ever lived
  /// in the index that went missing. `createdAt` comes from the file's own
  /// mtime, which is the closest thing to a capture time still on disk.
  Future<List<Recording>> findOrphans(List<Recording> indexed) async {
    final Directory directory = await recordingsDirectory();
    final Set<String> known =
        indexed.map((Recording item) => item.id).toSet();

    final List<Recording> orphans = <Recording>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      // Posters are derived artifacts, not sources; `p.extension` would read
      // one as a plain `.jpg` and re-adopt it as an image capture.
      if (name.endsWith('.thumb.jpg')) continue;

      final CaptureType? type = typeForExtension(p.extension(name));
      if (type == null) continue; // the three json files, `.tmp`, backups

      final String id = p.basenameWithoutExtension(name);
      if (known.contains(id)) continue;

      final FileStat stat = await entity.stat();
      if (stat.size == 0) continue; // never index an empty source

      orphans.add(
        Recording(
          id: id,
          filePath: entity.path,
          createdAt: stat.modified,
          durationMs: 0,
          sizeBytes: stat.size,
          status: RecordingStatus.saved,
          type: type,
        ),
      );
    }

    orphans.sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
    return orphans;
  }

  /// Copy [file] aside under a timestamped name and return the new path, or
  /// null if even the copy failed. Never throws: this runs on paths that are
  /// already going wrong, and failing to make a backup must not replace the
  /// error the caller is actually reporting.
  Future<String?> _preserve(File file, String reason) async {
    try {
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final String destination = p.join(
        p.dirname(file.path),
        '${p.basenameWithoutExtension(file.path)}.$reason-$stamp.json',
      );
      await file.copy(destination);
      return destination;
    } catch (_) {
      return null;
    }
  }

  Future<File> _indexFile() async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, 'recordings.json'));
  }
}
